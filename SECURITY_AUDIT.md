# Security Audit — rosa-regional-platform

> **Audit Date:** 2026-05-01  
> **Auditor:** Automated adversarial security agent  
> **Branch:** security-audit-agent-2026-05-01  
> **Scope:** Full repository static analysis — Terraform, Kubernetes/ArgoCD, CI/CD, Python scripts

---

## Summary

This repository manages the ROSA (Red Hat OpenShift Service on AWS) Regional Platform infrastructure, including EKS clusters, RDS databases, networking, IAM policies, and CI/CD pipelines. The audit identified **2 CRITICAL**, **4 HIGH**, **4 MEDIUM**, and **2 LOW** security findings. The most urgent issues are an overly permissive CodeBuild IAM role with wildcard permissions across critical AWS services, and an API Gateway resource policy that permits any authenticated AWS principal to invoke the platform API.

---

## Findings

### CRITICAL

---

**[CRITICAL] CodeBuild Pipeline Provisioner Role Grants Wildcard IAM, S3, Lambda, CodePipeline, and Route53 Permissions**

- **File:** `terraform/modules/pipeline-provisioner/iam.tf` (lines 56–68)
- **Category:** Infrastructure — IAM Policy
- **Issue:** The CodeBuild role used by the pipeline provisioner is granted unrestricted wildcard permissions across a broad set of critical AWS services:

  ```hcl
  "codepipeline:*",
  "codebuild:*",
  "codestar-connections:*",
  "iam:*",
  "s3:*",
  "route53:*",
  "lambda:*",
  "events:*"
  ```

  All of these actions apply to `Resource: "*"` without any conditions or resource-level restrictions. There is no SCP, permission boundary, or role path restriction compensating for this.

- **Attack Vector:** An attacker who compromises the CodeBuild build environment (via a supply chain attack on a CI dependency, a malicious pull request script, or stolen temporary credentials) inherits the full permissions of this role. They can create new IAM users or roles, attach admin policies, modify S3 buckets including the Terraform state backend, push code to any CodePipeline, and manipulate Route53 records.

- **Impact:** Complete AWS account takeover. Lateral movement to all resources in the account. Modification of CI/CD pipelines to distribute malware. Exfiltration of all secrets stored in S3 or Secrets Manager. Persistent backdoor creation using new IAM credentials.

- **Recommendation:** Replace each wildcard statement with a scoped allow list restricted to specific resource ARNs. For example, IAM actions should be limited to specific role paths and bounded by a permission boundary; S3 actions should be restricted to the terraform state bucket and artifacts bucket ARNs; Lambda actions to the specific function names used in the pipeline; Route53 to the specific hosted zone IDs. Consider attaching a permissions boundary to the CodeBuild role as a hard ceiling.

---

**[CRITICAL] API Gateway Resource Policy Allows Any Authenticated AWS Principal**

- **File:** `terraform/modules/api-gateway/resource-policy.tf` (lines 11–28)
- **Category:** Infrastructure — API Gateway Access Control
- **Issue:** The API Gateway resource policy includes a statement that allows `execute-api:Invoke` for `Principal: { AWS: "*" }` — meaning any IAM principal in any AWS account in the world can invoke this API, as long as they have valid AWS credentials:

  ```json
  {
    "Sid": "AllowAllAWSAccounts",
    "Effect": "Allow",
    "Principal": { "AWS": "*" },
    "Action": "execute-api:Invoke",
    "Resource": "arn:aws:execute-api:..."
  }
  ```

  The comment in code states that "the Platform API backend handles its own authorization." Defense in depth requires that the network/infrastructure layer not be a trust-all boundary.

- **Attack Vector:** Any compromised EC2 instance, Lambda function, or developer credential within the broader AWS ecosystem can make authenticated requests directly to the platform API. Exploitable even without breaking any internal systems — a credential from a third-party vendor or partner account is sufficient. Brute-forcing application-layer auth bugs becomes significantly easier when the API is reachable to any AWS principal.

- **Impact:** Unauthorized API invocations. If the application authorization layer has any flaw (logic bug, misconfigured Cedar policy, account ID confusion), an attacker with any AWS credentials gets a foothold. Increases the effective blast radius of every other application-layer vulnerability.

- **Recommendation:** Restrict the resource policy `Principal` to the AWS Organization using `aws:PrincipalOrgID`:

  ```json
  {
    "Condition": {
      "StringEquals": {
        "aws:PrincipalOrgID": "o-xxxxxxxxxx"
      }
    }
  }
  ```

  Or constrain to specific IAM role ARNs from specific accounts that legitimately invoke the API. Remove the `AllowAllAWSAccounts` statement entirely.

---

### HIGH

---

**[HIGH] SigV4 Proxy Deployment Uses Unpinned `:latest` Container Image**

- **File:** `argocd/config/management-cluster/monitoring/templates/sigv4-proxy-deployment.yaml` (line 21)
- **Category:** Supply Chain — Unpinned Image Tag
- **Issue:** The SigV4 proxy deployment — a network-critical component that handles AWS authentication for outbound requests — pulls from:

  ```yaml
  image: public.ecr.aws/aws-observability/aws-sigv4-proxy:latest
  ```

  The `:latest` tag is mutable. Any tag push to `latest` takes effect on the next pod restart.

- **Attack Vector:** If public.ecr.aws is compromised, or if an attacker finds a way to push to the upstream image tag, all clusters that restart this pod (during node upgrades, OOM kills, rollouts) will pull the attacker's image. Since this is a proxy handling AWS credentials signing, a compromised image could exfiltrate every AWS API credential it proxies.

- **Impact:** Credential exfiltration for all outbound AWS API calls, MitM of encrypted traffic, persistent cluster compromise.

- **Recommendation:** Pin to an immutable SHA256 digest:
  ```yaml
  image: public.ecr.aws/aws-observability/aws-sigv4-proxy@sha256:<verified-digest>
  ```

---

**[HIGH] CI Build Container Uses Unpinned `ubi9/ubi:latest` Base Image**

- **File:** `ci/Containerfile` (line 5)
- **Category:** Supply Chain — Unpinned Image Tag
- **Issue:** The CI build container base image is unpinned:

  ```dockerfile
  FROM registry.access.redhat.com/ubi9/ubi:latest
  ```

  Every CI build potentially pulls a different OS image with different packages, introducing non-determinism and supply chain risk.

- **Attack Vector:** A compromised or malicious update to the `ubi9/ubi:latest` tag injects malicious packages into all CI builds. Any binary, library, or tool installed on top of the base image runs in a potentially compromised environment. All artifacts produced by CI (container images, binaries) become suspect.

- **Impact:** Complete CI/CD compromise. All artifacts built by CI may be backdoored. Credentials available in CI environment can be exfiltrated.

- **Recommendation:** Pin to a specific image digest:
  ```dockerfile
  FROM registry.access.redhat.com/ubi9/ubi@sha256:<verified-digest>
  ```

---

**[HIGH] `eval` of Terraform Output Enables Code Injection**

- **File:** `scripts/dev/bastion-connect.sh` (line 234)
- **Category:** Application — Code Injection
- **Issue:** The script evaluates Terraform output directly:

  ```bash
  eval "$(terraform output -raw bastion_run_task_command)"
  ```

  If the Terraform state file has been tampered with (e.g., a state file injection attack, a compromised S3 backend, or a malicious PR that gets applied), the output can contain arbitrary shell code executed with the developer's full privileges.

- **Attack Vector:** An attacker who can write to the Terraform state S3 bucket (via misconfigured bucket policy, stolen credentials, or the overly permissive CodeBuild IAM role described in finding #1) injects malicious shell commands into the `bastion_run_task_command` output. When a developer runs this script, arbitrary commands execute locally with their privileges.

- **Impact:** Developer workstation compromise. Credential theft. Pivoting to resources the developer has access to.

- **Recommendation:** Avoid `eval` of dynamic content. Instead, parse specific fields from Terraform output (e.g., extract the task ARN and subnet ID individually and construct the command explicitly in the script using hardcoded patterns).

---

**[HIGH] Bastion ECS Task Granted `AmazonEKSClusterAdminPolicy` Without Scoping**

- **File:** `terraform/modules/bastion/jumphost-task.tf` (lines 201–218)
- **Category:** Infrastructure — Privilege / Least Privilege
- **Issue:** The bastion break-glass ECS task is associated with the AWS-managed `AmazonEKSClusterAdminPolicy` on the EKS cluster:

  ```hcl
  policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  ```

  This grants full `system:masters` equivalent access to the Kubernetes API server.

- **Attack Vector:** If the bastion container is compromised (malicious image, container escape from another task sharing the host, or an attacker who triggers the break-glass flow), they inherit cluster-admin on the EKS cluster. From there they can read all secrets, create privileged pods, modify RBAC, and deploy backdoors.

- **Impact:** Full Kubernetes cluster takeover from a single container compromise. All secrets, service account tokens, and workloads in the cluster are accessible. Lateral movement to any AWS service accessible from within the cluster.

- **Recommendation:** Replace the blanket cluster-admin policy with a tightly scoped Kubernetes RBAC role bound to only the operations that break-glass access legitimately requires. Use the `STANDARD` access policy type with a namespace-scoped ClusterRoleBinding rather than `CLUSTER_ADMIN`.

---

### MEDIUM

---

**[MEDIUM] AWS CLI and `yq` Downloaded Without Checksum Verification**

- **File:** `ci/Containerfile` (lines 74, 86)
- **Category:** Supply Chain — Binary Integrity
- **Issue:** The CI container installs AWS CLI v2 and `yq` via `curl` without verifying checksums, despite Terraform and Helm being verified:

  ```dockerfile
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}-${AWS_CLI_VERSION}.zip" -o "awscliv2.zip"
  # No checksum verification follows
  ```

- **Attack Vector:** A MITM attack or CDN compromise during container build serves a malicious binary. The absence of checksum verification means the tampered download is accepted silently. Since `awscli` is the primary tool for interacting with AWS in CI, a malicious build of it can exfiltrate every AWS credential it processes.

- **Impact:** Supply chain compromise of all CI-built artifacts and exfiltration of all AWS credentials handled by the compromised AWS CLI.

- **Recommendation:** Download and verify SHA256 checksums for both tools before installation. AWS publishes official checksums at `https://awscli.amazonaws.com/v2/release/sha256sums`.

---

**[MEDIUM] RDS Database Passwords Have No Rotation Mechanism**

- **File:** `terraform/modules/maestro-infrastructure/rds.tf` (lines 8–15)
- **Category:** Infrastructure — Secrets Management
- **Issue:** Database passwords are generated via `random_password` at Terraform apply time and stored in Terraform state. A comment acknowledges this is temporary: `# TODO: Will go once using ASCP for access`. There is no rotation schedule, no emergency rotation procedure, and no expiry.

- **Attack Vector:** If the Terraform state file is compromised (e.g., via the overly permissive S3 access granted to CodeBuild), the database password is exposed for the lifetime of the deployment — potentially years — with no mechanism to detect or recover from the exposure.

- **Impact:** Full database access for an attacker who reads the state file. All data in the Maestro RDS instance is exfilterable.

- **Recommendation:** Migrate immediately to AWS Secrets Manager with automatic rotation. Use IAM authentication for RDS as the final target state.

---

**[MEDIUM] Bastion Security Group Allows Unrestricted Egress**

- **File:** `terraform/modules/bastion/main.tf` (lines 33–39)
- **Category:** Infrastructure — Network Segmentation
- **Issue:**

  ```hcl
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }
  ```

- **Attack Vector:** An attacker with code execution in the bastion container can exfiltrate data to arbitrary external servers, establish a reverse shell to a command-and-control host, or port-scan other networks.

- **Impact:** Data exfiltration, persistent backdoor establishment, lateral movement to external systems.

- **Recommendation:** Restrict egress to: specific HTTPS (443) to VPC endpoints for SSM/ECR/S3, specific HTTPS to the EKS API endpoint security group, and no outbound to `0.0.0.0/0`. Use VPC endpoints to eliminate the need for internet egress.

---

**[MEDIUM] Authorization Service IAM Policy Allows Unrestricted Amazon Verified Permissions Access**

- **File:** `terraform/modules/authz/iam.tf` (lines 98–131)
- **Category:** Infrastructure — IAM Policy
- **Issue:** The Authorization Service IAM role grants unrestricted access to all AVP policy stores in the account (`Resource: "*"`), covering actions like `CreatePolicyStore`, `DeletePolicyStore`, and `CreatePolicy`. This means a compromised authorization service can modify authorization policies for all other applications.

- **Attack Vector:** A compromised authorization service pod can delete or overwrite policy stores for other applications, granting itself or an attacker elevated permissions, or deny access to legitimate users (denial of service).

- **Impact:** Cross-application privilege escalation, authorization bypass for any application using AVP in this account.

- **Recommendation:** Scope the `Resource` field to the specific policy store ARNs owned by the authorization service.

---

### LOW

---

**[LOW] Custom Control Plane Operator Image from Personal Quay.io Account**

- **File:** `argocd/config/regional-cluster/hyperfleet-adapter1-chart/manifestwork.yaml` (line 113)
- **Category:** Supply Chain — Image Provenance
- **Issue:** A custom-built control plane operator image from a personal Quay.io account is referenced:

  ```yaml
  hypershift.openshift.io/control-plane-operator-image: quay.io/cbusse_openshift/control-plane-operator:eks-compat-4.22-a1fa3e6cfa
  ```

  This is noted in comments as temporary (awaiting upstream backports), but personal registry accounts do not have organizational access controls.

- **Recommendation:** Move to an organizational registry with proper access controls. Track the upstream PR/issue and set a deadline for switching back to the official image.

---

**[LOW] Multiple TODO Comments Indicate Deferred Security Controls**

- **Files:** `terraform/modules/maestro-infrastructure/rds.tf`, multiple locations
- **Category:** Infrastructure — Security Debt
- **Issue:** Several TODO comments indicate incomplete security implementations (e.g., ASCP integration for secrets, policy document migration). These represent known gaps with no tracked completion timeline.

- **Recommendation:** Convert each security-related TODO into a tracked issue with an owner and target date. Add automated linting to flag new TODOs that touch security-relevant code paths.

