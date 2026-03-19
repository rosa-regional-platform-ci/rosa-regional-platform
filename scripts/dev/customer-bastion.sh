#!/bin/bash

set -euo pipefail

# Usage information
usage() {
  cat <<EOF
Usage: $0 [OPTIONS] <cluster-resource.json>

Deploy an ephemeral bastion in a customer's VPC for ROSA HCP cluster access.

Options:
  -i, --image IMAGE       Container image URI (default: from CloudFormation template)
  -c, --cleanup           Clean up the stack after disconnecting
  -f, --force-new         Force create new task even if one is running
  -s, --stack-name NAME   Custom CloudFormation stack name (default: bastion-CLUSTER_NAME)
  --cpu CPU               CPU units (256, 512, 1024, 2048, 4096)
  --memory MEMORY         Memory in MB (512-8192)
  -h, --help              Show this help message

Arguments:
  cluster-resource.json   Path to the cluster resource JSON file containing
                          the HostedCluster manifest

Examples:
  $0 cluster.json                           # Deploy bastion and connect
  $0 -c cluster.json                        # Deploy, connect, then cleanup
  $0 --stack-name my-bastion cluster.json   # Use custom stack name
  $0 -f cluster.json                        # Force new task

Note: The bastion provides shell access with pre-installed tools (kubectl, oc, etc.)
      but you need to provide a kubeconfig to access the cluster API.

EOF
  exit 1
}

# Parse options
CONTAINER_IMAGE=""
CLEANUP=false
FORCE_NEW=false
STACK_NAME=""
CPU=""
MEMORY=""
RESOURCE_FILE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -i|--image)
      CONTAINER_IMAGE="$2"
      shift 2
      ;;
    -c|--cleanup)
      CLEANUP=true
      shift
      ;;
    -f|--force-new)
      FORCE_NEW=true
      shift
      ;;
    -s|--stack-name)
      STACK_NAME="$2"
      shift 2
      ;;
    --cpu)
      CPU="$2"
      shift 2
      ;;
    --memory)
      MEMORY="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    -*)
      echo "Error: Unknown option '$1'"
      echo ""
      usage
      ;;
    *)
      RESOURCE_FILE="$1"
      shift
      ;;
  esac
done

# Validate resource file
if [ -z "$RESOURCE_FILE" ]; then
  echo "Error: cluster resource file is required"
  echo ""
  usage
fi

if [ ! -f "$RESOURCE_FILE" ]; then
  echo "Error: File not found: $RESOURCE_FILE"
  exit 1
fi

# Extract information from the cluster resource JSON
echo "==> Parsing cluster resource from $RESOURCE_FILE"

# Extract the HostedCluster manifest from the data.data.spec.workload.manifests array
HOSTED_CLUSTER=$(jq -r '.data.spec.workload.manifests[] | select(.kind == "HostedCluster")' "$RESOURCE_FILE")

if [ -z "$HOSTED_CLUSTER" ]; then
  echo "Error: Could not find HostedCluster manifest in resource file"
  exit 1
fi

# Extract cluster information
CLUSTER_NAME=$(echo "$HOSTED_CLUSTER" | jq -r '.metadata.name')
REGION=$(echo "$HOSTED_CLUSTER" | jq -r '.spec.platform.aws.region')
VPC_ID=$(echo "$HOSTED_CLUSTER" | jq -r '.spec.platform.aws.cloudProviderConfig.vpc')
SUBNET_ID=$(echo "$HOSTED_CLUSTER" | jq -r '.spec.platform.aws.cloudProviderConfig.subnet.id')

# Extract worker security group from NodePool
NODE_POOL=$(jq -r '.data.spec.workload.manifests[] | select(.kind == "NodePool")' "$RESOURCE_FILE")
WORKER_SG=$(echo "$NODE_POOL" | jq -r '.spec.platform.aws.securityGroups[0].id // empty')

if [ -z "$WORKER_SG" ]; then
  echo "Error: Could not find worker security group in NodePool manifest"
  echo "The worker security group is required for bastion connectivity"
  exit 1
fi

# Validate extracted values
if [ -z "$CLUSTER_NAME" ] || [ -z "$REGION" ] || [ -z "$VPC_ID" ] || [ -z "$SUBNET_ID" ]; then
  echo "Error: Failed to extract required information from resource file"
  echo "  Cluster Name: ${CLUSTER_NAME:-<missing>}"
  echo "  Region: ${REGION:-<missing>}"
  echo "  VPC ID: ${VPC_ID:-<missing>}"
  echo "  Subnet ID: ${SUBNET_ID:-<missing>}"
  exit 1
fi

echo "  Cluster Name: $CLUSTER_NAME"
echo "  Region: $REGION"
echo "  VPC ID: $VPC_ID"
echo "  Subnet ID: $SUBNET_ID"
echo "  Worker SG: $WORKER_SG"

# Default stack name if not provided
STACK_NAME=${STACK_NAME:-"bastion-${CLUSTER_NAME}"}

# Determine CloudFormation template path
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
CFN_TEMPLATE="$REPO_ROOT/cloudformation/customer-bastion.yaml"

if [ ! -f "$CFN_TEMPLATE" ]; then
  echo "Error: CloudFormation template not found at $CFN_TEMPLATE"
  exit 1
fi

# Build CloudFormation parameters
CFN_PARAMS="ParameterKey=ClusterName,ParameterValue=$CLUSTER_NAME"
CFN_PARAMS="$CFN_PARAMS ParameterKey=VpcId,ParameterValue=$VPC_ID"
CFN_PARAMS="$CFN_PARAMS ParameterKey=SubnetId,ParameterValue=$SUBNET_ID"
CFN_PARAMS="$CFN_PARAMS ParameterKey=WorkerSecurityGroupId,ParameterValue=$WORKER_SG"

if [ -n "$CONTAINER_IMAGE" ]; then
  CFN_PARAMS="$CFN_PARAMS ParameterKey=ContainerImage,ParameterValue=$CONTAINER_IMAGE"
fi

if [ -n "$CPU" ]; then
  CFN_PARAMS="$CFN_PARAMS ParameterKey=CPU,ParameterValue=$CPU"
fi

if [ -n "$MEMORY" ]; then
  CFN_PARAMS="$CFN_PARAMS ParameterKey=Memory,ParameterValue=$MEMORY"
fi

# Set AWS region
export AWS_REGION=$REGION
export AWS_DEFAULT_REGION=$REGION

# Check if stack already exists
echo ""
echo "==> Checking for existing CloudFormation stack: $STACK_NAME"

if aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" &>/dev/null; then
  echo "==> Stack exists, updating..."

  # Update stack
  UPDATE_OUTPUT=$(aws cloudformation update-stack \
    --stack-name "$STACK_NAME" \
    --template-body "file://$CFN_TEMPLATE" \
    --parameters $CFN_PARAMS \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "$REGION" 2>&1 || true)

  if echo "$UPDATE_OUTPUT" | grep -q "No updates are to be performed"; then
    echo "==> No updates needed for stack"
  else
    echo "==> Waiting for stack update to complete..."
    aws cloudformation wait stack-update-complete \
      --stack-name "$STACK_NAME" \
      --region "$REGION"
    echo "==> Stack update complete"
  fi
else
  echo "==> Stack does not exist, creating..."

  # Create stack
  aws cloudformation create-stack \
    --stack-name "$STACK_NAME" \
    --template-body "file://$CFN_TEMPLATE" \
    --parameters $CFN_PARAMS \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "$REGION" \
    --no-cli-pager > /dev/null

  echo "==> Waiting for stack creation to complete..."
  aws cloudformation wait stack-create-complete \
    --stack-name "$STACK_NAME" \
    --region "$REGION"
  echo "==> Stack creation complete"
fi

# Get stack outputs
echo ""
echo "==> Getting stack outputs..."

ECS_CLUSTER=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`ClusterName`].OutputValue' \
  --output text)

TASK_DEFINITION_FAMILY=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`TaskDefinitionFamily`].OutputValue' \
  --output text)

SECURITY_GROUP=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`BastionSecurityGroupId`].OutputValue' \
  --output text)

# Check for existing running task
echo ""
echo "==> Checking for running bastion tasks..."

EXISTING_TASK=$(aws ecs list-tasks \
  --cluster "$ECS_CLUSTER" \
  --desired-status RUNNING \
  --region "$REGION" \
  --query 'taskArns[0]' \
  --output text)

if [ -n "$EXISTING_TASK" ] && [ "$EXISTING_TASK" != "None" ] && [ "$FORCE_NEW" = false ]; then
  TASK_ID=$(echo "$EXISTING_TASK" | awk -F'/' '{print $NF}')
  echo "==> Found existing running task: $TASK_ID"
  echo "==> Reconnecting to existing task..."
  echo "    (Use --force-new flag to create a new task)"
else
  if [ "$FORCE_NEW" = true ]; then
    echo "==> --force-new flag specified, starting a new task..."
  else
    echo "==> No existing task found, starting a new one..."
  fi

  # Start new task
  echo "==> Starting bastion task..."

  TASK_ARN=$(aws ecs run-task \
    --cluster "$ECS_CLUSTER" \
    --task-definition "$TASK_DEFINITION_FAMILY" \
    --launch-type FARGATE \
    --enable-execute-command \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID],securityGroups=[$SECURITY_GROUP],assignPublicIp=DISABLED}" \
    --region "$REGION" \
    --query 'tasks[0].taskArn' \
    --output text)

  TASK_ID=$(echo "$TASK_ARN" | awk -F'/' '{print $NF}')

  echo "==> Task started: $TASK_ID"
  echo "==> Waiting for task to be running..."

  aws ecs wait tasks-running \
    --cluster "$ECS_CLUSTER" \
    --tasks "$TASK_ID" \
    --region "$REGION"
fi

# Get runtime ID for reference
RUNTIME_ID=$(aws ecs describe-tasks \
  --cluster "$ECS_CLUSTER" \
  --tasks "$TASK_ID" \
  --region "$REGION" \
  --query 'tasks[0].containers[?name==`bastion`].runtimeId | [0]' \
  --output text)

echo ""
echo "=== Bastion ready for $CLUSTER_NAME ==="
echo "    Stack: $STACK_NAME"
echo "    Cluster: $ECS_CLUSTER"
echo "    Task ID: $TASK_ID"
echo "    Runtime ID: $RUNTIME_ID"
echo ""
echo "==> Connecting to bastion..."
echo ""

# Connect via ECS Exec
aws ecs execute-command \
  --cluster "$ECS_CLUSTER" \
  --task "$TASK_ID" \
  --container bastion \
  --interactive \
  --region "$REGION" \
  --command '/bin/bash'

# Cleanup if requested
if [ "$CLEANUP" = true ]; then
  echo ""
  echo "==> Cleaning up..."

  # Stop the task
  echo "==> Stopping task $TASK_ID..."
  aws ecs stop-task \
    --cluster "$ECS_CLUSTER" \
    --task "$TASK_ID" \
    --region "$REGION" \
    --no-cli-pager > /dev/null

  # Delete the stack
  echo "==> Deleting CloudFormation stack $STACK_NAME..."
  aws cloudformation delete-stack \
    --stack-name "$STACK_NAME" \
    --region "$REGION"

  echo "==> Waiting for stack deletion to complete..."
  aws cloudformation wait stack-delete-complete \
    --stack-name "$STACK_NAME" \
    --region "$REGION"

  echo "==> Cleanup complete"
fi

echo ""
echo "==> Done"
