# Security Audit — rosa-regional-platform

**Audit Date:** 2026-05-15  
**Auditor:** security-audit-agent  
**Severity Labels:** CRITICAL / HIGH / MEDIUM / LOW

---

## Finding 1 — HIGH: Unpinned `:latest` Container Image Tags (Supply Chain Risk)

**Files:**
- `ci/Containerfile:5` — `FROM registry.access.redhat.com/ubi9/ubi:latest`
- `argocd/config/management-cluster/monitoring/templates/sigv4-proxy-deployment.yaml:21` — `image: public.ecr.aws/aws-observability/aws-sigv4-proxy:latest`
- `.spec/001-agent-vm-isolation/egress-proxy-spec.yaml:152` — `"<account>.dkr.ecr.<region>.amazonaws.com/agent-egress-proxy:latest"`

**Risk:**  
Using `:latest` (or implicit latest) image tags means that any push to the underlying registry silently changes what code runs in your infrastructure. This is a supply chain attack vector: if the upstream registry is compromised, or if a new image version introduces breaking changes or malicious code, there is no pinning to prevent deployment.

**Attack Vector:**  
1. Attacker compromises `public.ecr.aws/aws-observability/aws-sigv4-proxy` or the quay.io/ECR image registry.
2. Pushes a malicious image with the same `:latest` tag.
3. Next pod restart or ArgoCD sync pulls the malicious image, which now runs inside the management cluster with the sigv4-proxy service account privileges.

For the CI Containerfile, a compromised base image executes in the CI/CD pipeline with access to repository secrets, build credentials, and potentially AWS credentials.

**What to Mitigate:**  
Pin all image references to a specific digest (SHA256) or at minimum a version tag. For example:
- `public.ecr.aws/aws-observability/aws-sigv4-proxy@sha256:<digest>` or a versioned tag like `:1.x.y`
- `registry.access.redhat.com/ubi9/ubi:9.x-<build>`

---

## Finding 2 — HIGH: Unrestricted Egress (0.0.0.0/0) on Stateful Service Security Groups

**Files:**
- `terraform/modules/hyperfleet-infrastructure/rds.tf:68-73` — RDS PostgreSQL SG has unrestricted egress
- `terraform/modules/maestro-infrastructure/rds.tf:73-78` — Same pattern for Maestro RDS
- `terraform/modules/hyperfleet-infrastructure/amazonmq.tf:55-60` — AmazonMQ broker SG has unrestricted egress

**Risk:**  
RDS PostgreSQL instances and Amazon MQ brokers are pure data-store services; they never need to initiate outbound connections to the internet. Permitting unrestricted egress (`0.0.0.0/0`) on these security groups violates least-privilege networking and creates unnecessary attack surface.

**Attack Vector:**  
If an attacker achieves RCE on the database (e.g., via a stored procedure, PostgreSQL `COPY TO PROGRAM`, or a compromised message broker plugin), they could use the database's network identity to exfiltrate data to external endpoints, establish C2 communication, or pivot to other internal services. The unrestricted egress acts as a beachhead for data exfiltration.

**Specific Concern:**  
- RDS `COPY TO PROGRAM` (if `pg_execute_server_program` is granted) with unrestricted egress can exfiltrate data directly from the database server.
- A compromised RabbitMQ plugin could reach external servers for command and control.

**What to Mitigate:**  
Remove the egress `0.0.0.0/0` rules from these security groups entirely (RDS and MQ services do not initiate outbound connections). If AWS service-managed connectivity is needed (e.g., for enhanced monitoring), scope to specific VPC endpoints or AWS-managed CIDRs only.

---

## Finding 3 — HIGH: ECS Task Security Groups with Unrestricted Egress — No VPC Endpoint Enforcement

**Files:**
- `terraform/modules/bastion/main.tf:35-42` — Bastion task: egress `0.0.0.0/0`
- `terraform/modules/ecs-bootstrap/security-groups.tf:11-19` — Bootstrap task: egress `0.0.0.0/0` and `::/0`

**Risk:**  
While the comment acknowledges "needed for tool downloads, EKS API, SSM endpoints," the VPC has VPC endpoints configured for SSM and other AWS services. Blanket `0.0.0.0/0` egress means a compromised container in the bastion or bootstrap task can reach any internet destination — not just necessary AWS services.

**Attack Vector:**  
A compromised bastion container (via a malicious tool binary downloaded at runtime, RCE in a kubectl plugin, etc.) can exfiltrate `~/.kube/config` credentials, the EKS service account tokens, or AWS instance metadata credentials to attacker-controlled endpoints, without any network-layer barrier.

**What to Mitigate:**  
Restrict egress to:
- VPC endpoints for AWS services (SSM, ECR, EKS, etc. — already deployed in the EKS network module)
- Known registry CIDRs (registry.access.redhat.com, etc.) if images are still pulled directly
- Or use an egress proxy (as the `.spec/001-agent-vm-isolation` spec describes) to allowlist specific hostnames

---

## Finding 4 — MEDIUM: S3 Pipeline Artifact Bucket Missing Server-Side Encryption (Management Cluster)

**File:** `terraform/config/pipeline-management-cluster/main.tf:283-330`

**Risk:**  
The `pipeline-management-cluster` S3 artifact bucket (`aws_s3_bucket.pipeline_artifact`) has versioning, lifecycle, and public access block configured — but no `aws_s3_bucket_server_side_encryption_configuration` resource. In contrast, `terraform/config/pipeline-regional-cluster/main.tf:190-198` correctly has SSE configured.

This bucket stores CodePipeline artifacts for the management cluster, which can include Terraform state references, deployment scripts, and CI/CD configuration. Unencrypted artifacts at rest can be exposed via:
- Accidental policy misconfiguration that grants public or cross-account read
- S3 data export or log files that include object content
- AWS support access (S3 SSE-KMS prevents even AWS from reading contents)

**What to Mitigate:**  
Add `aws_s3_bucket_server_side_encryption_configuration` to the management cluster pipeline artifact bucket, matching the pattern used in the regional cluster config. Consider using SSE-KMS (customer-managed key) rather than SSE-S3 for stronger auditability.

---

## Finding 5 — HIGH: Cluster-Cleanup CronJob Downloads `kubectl` at Runtime Without Integrity Verification

**File:** `argocd/config/regional-cluster/cluster-cleanup/templates/cronjob.yaml:72-73`

```sh
wget -qO /usr/local/bin/kubectl "https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl
```

**Risk:**  
This CronJob downloads the `kubectl` binary from the internet at runtime, without verifying its SHA256 checksum or GPG signature. This pattern is a textbook supply chain attack vector: 

**Attack Vectors:**
1. **DNS hijacking / BGP hijacking:** Traffic to `dl.k8s.io` could be intercepted on the network path, serving a backdoored `kubectl` binary.
2. **CDN/distribution compromise:** If `dl.k8s.io` is compromised, every cluster runs the attacker's binary.
3. **TLS MITM (rare but possible):** In environments with TLS inspection proxies, a misconfigured proxy could serve an arbitrary binary.

The downloaded binary runs in a pod with `hyperfleet-api-sa` service account and PostgreSQL database access (`PGPASSWORD` from secrets). A malicious binary could exfiltrate database credentials, manipulate cluster state, or use the service account to interact with the Kubernetes API.

**Additional Concern:**  
The binary version is hardcoded to `v1.31.0/linux/amd64`, making it incompatible with aarch64 nodes and fragile to upstream file moves.

**What to Mitigate:**  
1. Build `kubectl` into the container image used by the CronJob (bake it in at image build time with checksum verification).
2. If downloading at runtime is necessary, verify the SHA256 checksum: Kubernetes publishes checksums at `https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl.sha256`.

---

## Finding 6 — MEDIUM: `secretsmanager:*` in Pipeline IAM Policy (Overly Broad)

**File:** `terraform/config/pipeline-management-cluster/main.tf` (CodeBuild IAM policy)

```hcl
# Secrets Manager - For Maestro agent secrets
"secretsmanager:*",
```

**Risk:**  
Granting `secretsmanager:*` gives the CodeBuild pipeline role the ability to read, create, update, delete, rotate, and replicate **all** Secrets Manager secrets in the account. If the CodeBuild environment is compromised (e.g., malicious build script injected via a PR, compromised GitHub webhook), an attacker could exfiltrate all secrets in the account.

**What to Mitigate:**  
Scope the Secrets Manager permissions to the specific secret ARNs or a path prefix that the pipeline actually needs (e.g., `arn:aws:secretsmanager:*:${AccountId}:secret:/infra/maestro-*`). Replace `secretsmanager:*` with the specific actions needed (`GetSecretValue`, `DescribeSecret`) on specific resources.

---

## Finding 7 — MEDIUM: CI Containerfile AWS CLI Download Missing GPG Signature Verification

**File:** `ci/Containerfile`

The AWS CLI download in `ci/Containerfile` does not verify the GPG signature of the downloaded package:
```sh
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}-${AWS_CLI_VERSION}.zip" -o "awscliv2.zip"
unzip -qo awscliv2.zip && ./aws/install
```

Compare with `aws-nuke-cf/Containerfile`, which correctly verifies the GPG signature:
```sh
curl -fsSL "...awscliv2.zip.sig" -o "awscliv2.zip.sig"
gpg --keyserver keyserver.ubuntu.com --recv-keys FB5DB77FD5C118B80511ADA8A6310ACC4672475C
gpg --verify awscliv2.zip.sig awscliv2.zip
```

**Risk:**  
A compromised AWS CLI binary could execute arbitrary code with the CI pipeline's IAM permissions (AWS CodeBuild execution role), potentially exfiltrating infrastructure secrets or modifying Terraform state.

**What to Mitigate:**  
Add GPG signature verification matching the pattern already in `aws-nuke-cf/Containerfile`.
