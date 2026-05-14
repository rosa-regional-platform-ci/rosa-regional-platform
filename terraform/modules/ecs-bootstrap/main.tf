# ECS Bootstrap Module for ArgoCD
# Provides ECS Fargate infrastructure for external bootstrap execution

locals {
  bootstrap_container_name = "bootstrap"
  log_retention_days       = 365
}

# Current AWS region information
data "aws_region" "current" {}

# ECS Cluster for bootstrap tasks
resource "aws_ecs_cluster" "bootstrap" {
  name = "${var.cluster_id}-bootstrap"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# KMS key for CloudWatch log group encryption (FedRAMP AU-09)
resource "aws_kms_key" "bootstrap_logs" {
  description             = "KMS key for ECS bootstrap CloudWatch log group encryption (FedRAMP AU-09)"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${data.aws_region.current.name}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name = "${var.cluster_id}-bootstrap-logs"
  }
}

# CloudWatch Log Group for bootstrap tasks
resource "aws_cloudwatch_log_group" "bootstrap" {
  name              = "/ecs/${var.cluster_id}/bootstrap"
  retention_in_days = local.log_retention_days
  kms_key_id        = aws_kms_key.bootstrap_logs.arn

  depends_on = [aws_kms_key.bootstrap_logs]
}

# ECS Task Definition for bootstrap execution
resource "aws_ecs_task_definition" "bootstrap" {
  family                   = "${var.cluster_id}-bootstrap"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name  = local.bootstrap_container_name
      image = var.container_image

      entryPoint = ["/bin/bash", "-c"]
      command = [
        <<-EOF
          set -euo pipefail

          echo "=== ArgoCD Bootstrap ==="
          echo "Tools: aws=$(aws --version 2>&1 | head -1), kubectl=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion'), helm=$(helm version --short)"

          # Configure kubectl for EKS
          aws eks update-kubeconfig --name $CLUSTER_NAME

          # Pre-flight: apply FIPS NodeClass and NodePool so Karpenter can provision
          # nodes for ArgoCD pods to schedule on. ArgoCD adopts these on first sync.
          echo "Applying FIPS NodeClass and NodePool before ArgoCD install..."

          NODEPOOL_NAME="management-workloads"
          if [[ "$CLUSTER_TYPE" == "regional-cluster" ]]; then
            NODEPOOL_NAME="regional-workloads"
          fi

          cat <<-NODECLASS_EOF | kubectl apply -f -
          apiVersion: eks.amazonaws.com/v1
          kind: NodeClass
          metadata:
            name: fips
          spec:
            role: "$CLUSTER_NAME-auto-node-role"
            subnetSelectorTerms:
              - tags:
                  "kubernetes.io/cluster/$CLUSTER_NAME": owned
            securityGroupSelectorTerms:
              - tags:
                  aws:eks:cluster-name: "$CLUSTER_NAME"
            advancedSecurity:
              fips: true
              kernelLockdown: Integrity
          NODECLASS_EOF

          cat <<-NODEPOOL_EOF | kubectl apply -f -
          apiVersion: karpenter.sh/v1
          kind: NodePool
          metadata:
            name: $NODEPOOL_NAME
          spec:
            template:
              spec:
                nodeClassRef:
                  group: eks.amazonaws.com
                  kind: NodeClass
                  name: fips
                requirements:
                  - key: karpenter.sh/capacity-type
                    operator: In
                    values:
                      - on-demand
                  - key: kubernetes.io/arch
                    operator: In
                    values:
                      - amd64
            limits:
              cpu: "64"
              memory: 256Gi
            disruption:
              consolidationPolicy: WhenEmpty
              consolidateAfter: 60s
          NODEPOOL_EOF

          echo "✓ FIPS NodeClass and NodePool applied"

          # Create Deployment-based addons first so their pending pods trigger Karpenter
          # to provision a FIPS node. Karpenter is reactive — it only provisions nodes
          # in response to unschedulable pods; applying a NodePool alone is not enough.
          for ADDON in coredns metrics-server; do
            echo "Creating $ADDON add-on..."
            if CREATE_OUTPUT=$(aws eks create-addon \
                --cluster-name "$CLUSTER_NAME" \
                --addon-name "$ADDON" \
                --region "$AWS_REGION" 2>&1); then
              echo "  $ADDON created"
            elif echo "$CREATE_OUTPUT" | grep -q "ResourceInUseException"; then
              echo "  $ADDON already exists"
            else
              echo "$CREATE_OUTPUT" >&2
              exit 1
            fi
          done

          # Wait for Karpenter to provision a FIPS node (triggered by addon pending pods above).
          echo "Waiting for FIPS node to be ready (up to 10 minutes)..."
          deadline=$(($(date +%s) + 600))
          until kubectl get nodes --no-headers 2>/dev/null | grep -q " Ready"; do
            if [ $(date +%s) -ge $deadline ]; then
              echo "ERROR: No FIPS nodes became ready within 10 minutes"
              echo "--- nodes ---"
              kubectl get nodes -o wide 2>/dev/null || true
              echo "--- nodeclaims (karpenter provisioning attempts) ---"
              kubectl get nodeclaims 2>/dev/null || echo "none"
              echo "--- pending pods (kube-system) ---"
              kubectl get pods -n kube-system --field-selector=status.phase=Pending -o wide 2>/dev/null || true
              echo "--- all pending pods ---"
              kubectl get pods -A --field-selector=status.phase=Pending 2>/dev/null || true
              exit 1
            fi
            sleep 15
          done
          echo "✓ FIPS node ready"

          for ADDON in coredns metrics-server; do
            aws eks wait addon-active \
              --cluster-name "$CLUSTER_NAME" \
              --addon-name "$ADDON" \
              --region "$AWS_REGION"
            echo "✓ $ADDON active"
          done

          # Check if ArgoCD already exists
          if ! kubectl get deployment argocd-server -n argocd 2>/dev/null; then
            echo "Installing ArgoCD via Helm..."

            # Add ArgoCD Helm repository
            helm repo add argo https://argoproj.github.io/argo-helm
            helm repo update

            # Create argocd namespace
            kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

            ARGOCD_VERSION="9.3.4"
            # Install ArgoCD with adoption annotations for self-management handoff
            helm upgrade --install argocd argo/argo-cd \
              --namespace argocd \
              --version $ARGOCD_VERSION \
              --set-string 'controller.annotations.argocd\.argoproj\.io/tracking-id=argocd-self-management:argoproj.io/Application:argocd/argocd-self-management' \
              --set-string 'server.annotations.argocd\.argoproj\.io/tracking-id=argocd-self-management:argoproj.io/Application:argocd/argocd-self-management' \
              --set-string 'repoServer.annotations.argocd\.argoproj\.io/tracking-id=argocd-self-management:argoproj.io/Application:argocd/argocd-self-management' \
              --wait --timeout=5m

            echo "✓ ArgoCD installation complete"

            # Wait for ArgoCD to be ready
            kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n argocd
            kubectl wait --for=condition=available --timeout=600s deployment/argocd-repo-server -n argocd
            kubectl wait --for=condition=available --timeout=600s deployment/argocd-applicationset-controller -n argocd

            echo "✓ ArgoCD is running and ready"
          else
            echo "✓ ArgoCD is already installed and running, skipping installation"
          fi

          echo "Creating/updating cluster identity secret with values:"
          echo "  ENVIRONMENT: $ENVIRONMENT"
          echo "  AWS_REGION: $AWS_REGION"
          echo "  REGION_DEPLOYMENT: $REGION_DEPLOYMENT"
          echo "  CLUSTER_NAME: $CLUSTER_NAME"
          echo "  CLUSTER_TYPE: $CLUSTER_TYPE"
          echo "  REPOSITORY_URL: $REPOSITORY_URL"
          echo "  REPOSITORY_BRANCH: $REPOSITORY_BRANCH"
          
          cat <<-SECRET_EOF | kubectl apply -f -
          apiVersion: v1
          kind: Secret
          metadata:
            name: local-cluster-identity
            namespace: argocd
            labels:
              argocd.argoproj.io/secret-type: cluster
              environment: "$ENVIRONMENT"
              region_deployment: "$REGION_DEPLOYMENT"
              aws_region: "$AWS_REGION"
              cluster_type: "$CLUSTER_TYPE"
              cluster_name: "$CLUSTER_NAME"
            annotations:
              git_repo: "$REPOSITORY_URL"
              git_revision: "$REPOSITORY_BRANCH"
              api_target_group_arn: "$API_TARGET_GROUP_ARN"
              dynamodb_prefix: "$CLUSTER_NAME"
              dynamodb_region: "$AWS_REGION"
              thanos_kms_key_arn: "$THANOS_KMS_KEY_ARN"
              thanos_target_group_arn: "$THANOS_TARGET_GROUP_ARN"
              thanos_query_target_group_arn: "$THANOS_QUERY_TARGET_GROUP_ARN"
              aws_account_id: "$AWS_ACCOUNT_ID"
              rhobs_api_url: "$RHOBS_API_URL"
          type: Opaque
          stringData:
            name: in-cluster
            server: https://kubernetes.default.svc
            config: |
              {
                "tlsClientConfig": { "insecure": false }
              }
          SECRET_EOF

          echo "Creating/updating ArgoCD Root Application..."
          echo "  Repository URL: $REPOSITORY_URL"
          echo "  Target Revision: $REPOSITORY_BRANCH"
          echo "  Target Path: $REPOSITORY_PATH"
          
          cat <<-APP_EOF | kubectl apply -f -
          apiVersion: argoproj.io/v1alpha1
          kind: Application
          metadata:
            name: root
            namespace: argocd
          spec:
            destination:
              namespace: argocd
              server: https://kubernetes.default.svc
            project: default
            source:
              repoURL: $REPOSITORY_URL
              targetRevision: $REPOSITORY_BRANCH
              path: $REPOSITORY_PATH
            syncPolicy:
              automated:
                prune: false
                selfHeal: true
              syncOptions:
                - CreateNamespace=true
          APP_EOF

          echo "=== Bootstrap completed successfully ==="
        EOF
      ]

      essential = true

      environment = [
        {
          name  = "AWS_DEFAULT_REGION"
          value = data.aws_region.current.id
        },
        {
          name  = "THANOS_KMS_KEY_ARN"
          value = var.thanos_kms_key_arn
        },
        {
          name  = "AWS_ACCOUNT_ID"
          value = data.aws_caller_identity.current.account_id
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.bootstrap.name
          awslogs-region        = data.aws_region.current.id
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])
}