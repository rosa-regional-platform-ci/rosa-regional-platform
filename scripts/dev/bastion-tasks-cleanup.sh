#!/bin/bash

set -euo pipefail

# Usage information
usage() {
  echo "Usage: $0 [regional|management]"
  echo ""
  echo "Stop all running bastion ECS tasks"
  echo ""
  echo "Arguments:"
  echo "  regional    - Use regional cluster bastion (default)"
  echo "  management  - Use management cluster bastion"
  exit 1
}

# Default to regional if no argument provided
CLUSTER_TYPE=${1:-regional}

# Validate cluster type
case $CLUSTER_TYPE in
  regional|management)
    CONFIG_DIR="terraform/config/${CLUSTER_TYPE}-cluster"
    ;;
  *)
    echo "Error: Invalid cluster type '$CLUSTER_TYPE'"
    echo ""
    usage
    ;;
esac

# Verify terraform config directory exists
if [ ! -d "$CONFIG_DIR" ]; then
  echo "Error: Terraform config directory '$CONFIG_DIR' not found"
  exit 1
fi

# Get terraform outputs
cd $CONFIG_DIR
CLUSTER=$(terraform output -raw bastion_ecs_cluster_name)

# Find running tasks
TASK_ARNS=$(aws ecs list-tasks --cluster $CLUSTER --query 'taskArns[]' --output text)

if [[ -z "$TASK_ARNS" || "$TASK_ARNS" == "None" ]]; then
  echo "No running bastion tasks found in cluster '$CLUSTER'"
  exit 0
fi

echo "==> Stopping bastion tasks for $CLUSTER_TYPE cluster..."
echo "    Cluster: $CLUSTER"

for TASK_ARN in $TASK_ARNS; do
  TASK_ID=$(echo $TASK_ARN | awk -F'/' '{print $NF}')
  echo "    Stopping task: $TASK_ID"
  aws ecs stop-task --cluster $CLUSTER --task $TASK_ID --output text > /dev/null
done

echo "==> All bastion tasks stopped."
