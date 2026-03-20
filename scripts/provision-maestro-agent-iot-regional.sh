#!/bin/bash
set -euo pipefail

# =============================================================================
# Provision IoT Resources for Management Cluster (REGIONAL CONTEXT)
# =============================================================================
# This script provisions AWS IoT Thing, Certificate, and Policy for a
# management cluster in the REGIONAL AWS account. State is stored persistently
# in the regional account's S3 state bucket.
#
# Prerequisites:
# - AWS credentials configured for REGIONAL account
# - Terraform installed
# - jq installed (for JSON parsing)
# - State bucket exists in regional account (run bootstrap-state.sh first)
#
# Usage:
#   ./scripts/provision-maestro-agent-iot-regional.sh <path-to-management-cluster-tfvars>
#
# Example:
#   ./scripts/provision-maestro-agent-iot-regional.sh \
#     terraform/config/management-cluster/terraform.tfvars
#
# Output:
#   IoT resources provisioned with state stored in S3
# =============================================================================

# Color codes for output
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Script directory and paths
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly TERRAFORM_DIR="${REPO_ROOT}/terraform/config/maestro-agent-iot-provisioning"

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
  echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
  echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
  echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
  echo -e "${RED}✗${NC} $1" >&2
}

# Extract a variable value from a Terraform tfvars file
extract_tfvar() {
  local file="$1"
  local var="$2"

  grep "^${var}[[:space:]]*=" "$file" | \
    sed -E 's/^[^=]+=[[:space:]]*"([^"]+)".*/\1/' | \
    tr -d '\n'
}

# =============================================================================
# Argument Validation
# =============================================================================

if [ $# -ne 1 ]; then
  log_error "Usage: $0 <path-to-management-cluster-tfvars>"
  log_info "Example: $0 terraform/config/management-cluster/terraform.tfvars"
  exit 1
fi

MGMT_TFVARS="$1"

if [ ! -f "$MGMT_TFVARS" ]; then
  log_error "Management cluster tfvars file not found: ${MGMT_TFVARS}"
  exit 1
fi

if ! command -v jq &> /dev/null; then
  log_error "jq is required but not installed"
  log_info "Install with: sudo yum install jq  OR  sudo apt-get install jq"
  exit 1
fi

if ! command -v terraform &> /dev/null; then
  log_error "terraform is required but not installed"
  log_info "Install from: https://www.terraform.io/downloads"
  exit 1
fi

# =============================================================================
# Verify AWS Context (Regional Account)
# =============================================================================

log_info "Verifying AWS credentials (should be REGIONAL account)..."
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo "")}"

if [ -z "$AWS_ACCOUNT_ID" ]; then
  log_error "Unable to verify AWS credentials. Ensure you're authenticated."
  exit 1
fi

if [ -z "$AWS_REGION" ]; then
  log_error "AWS region not configured. Set it with: aws configure set region <region>"
  exit 1
fi

log_success "AWS credentials verified"
log_info "  Account ID: ${AWS_ACCOUNT_ID}"
log_info "  Region:     ${AWS_REGION}"
log_warning "  Ensure this is your REGIONAL account!"
echo ""

# =============================================================================
# Parse Management Cluster Configuration
# =============================================================================

log_info "Parsing management cluster configuration from: ${MGMT_TFVARS}"

CLUSTER_ID=$(extract_tfvar "$MGMT_TFVARS" "cluster_id")
APP_CODE=$(extract_tfvar "$MGMT_TFVARS" "app_code")
SERVICE_PHASE=$(extract_tfvar "$MGMT_TFVARS" "service_phase")
COST_CENTER=$(extract_tfvar "$MGMT_TFVARS" "cost_center")

# Validate required variables
if [ -z "$CLUSTER_ID" ]; then
  log_error "cluster_id not found in ${MGMT_TFVARS}"
  exit 1
fi

if [ -z "$APP_CODE" ] || [ -z "$SERVICE_PHASE" ] || [ -z "$COST_CENTER" ]; then
  log_error "Required tagging variables (app_code, service_phase, cost_center) not found"
  exit 1
fi

log_success "Configuration parsed successfully"
log_info "  Management Cluster: ${CLUSTER_ID}"
echo ""

# =============================================================================
# Configure State Backend
# =============================================================================

if [ "$AWS_REGION" = "us-east-1" ]; then
    IOT_STATE_BUCKET="${IOT_STATE_BUCKET:-terraform-state-${AWS_ACCOUNT_ID}}"
else
    IOT_STATE_BUCKET="${IOT_STATE_BUCKET:-terraform-state-${AWS_ACCOUNT_ID}-${AWS_REGION}}"
fi
IOT_STATE_KEY="${IOT_STATE_KEY:-maestro-agent-iot/${CLUSTER_ID}.tfstate}"
IOT_STATE_REGION="${IOT_STATE_REGION:-${AWS_REGION}}"

log_info "State backend:"
log_info "  Bucket: ${IOT_STATE_BUCKET}"
log_info "  Key:    ${IOT_STATE_KEY}"
log_info "  Region: ${IOT_STATE_REGION}"
echo ""

# =============================================================================
# Generate Terraform Variables
# =============================================================================

log_info "Generating terraform.tfvars for IoT provisioning..."

cd "$TERRAFORM_DIR"

cat > terraform.tfvars <<EOF
# Generated by provision-maestro-agent-iot-regional.sh
# Source: ${MGMT_TFVARS}

management_cluster_id = "${CLUSTER_ID}"
app_code              = "${APP_CODE}"
service_phase         = "${SERVICE_PHASE}"
cost_center           = "${COST_CENTER}"
mqtt_topic_prefix     = "sources/maestro/consumers"
EOF

log_success "terraform.tfvars generated"
echo ""

# =============================================================================
# Run Terraform
# =============================================================================

log_info "Initializing Terraform with remote backend..."
terraform init -reconfigure \
    -backend-config="bucket=${IOT_STATE_BUCKET}" \
    -backend-config="key=${IOT_STATE_KEY}" \
    -backend-config="region=${IOT_STATE_REGION}" \
    -backend-config="use_lockfile=true"

log_info "Running Terraform plan..."
terraform plan -out=tfplan

echo ""
if [ "${AUTO_APPROVE:-}" = "true" ]; then
  log_info "Auto-approve enabled, proceeding with apply..."
else
  read -p "$(echo -e ${YELLOW}Continue with terraform apply? [y/N]:${NC} )" -n 1 -r
  echo ""

  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_warning "Terraform apply cancelled"
    rm -f tfplan
    exit 0
  fi
fi

log_info "Applying Terraform configuration..."
terraform apply tfplan
rm -f tfplan

log_success "IoT resources provisioned in regional account"
echo ""

# =============================================================================
# Display Summary
# =============================================================================

echo "=============================================================================="
echo -e "${GREEN}Regional Provisioning Complete!${NC}"
echo "=============================================================================="
echo ""
echo "Resources created in REGIONAL account (${AWS_ACCOUNT_ID}):"
echo "  IoT Policy: ${CLUSTER_ID}-maestro-agent-policy"
echo "  Region:     ${AWS_REGION}"
echo ""
echo "State stored in:"
echo "  Bucket: ${IOT_STATE_BUCKET}"
echo "  Key:    ${IOT_STATE_KEY}"
echo ""
echo "=============================================================================="
echo "NEXT STEP"
echo "=============================================================================="
echo ""
echo "Deploy the management cluster infrastructure:"
echo ""
echo -e "${YELLOW}Deploy the management cluster infrastructure via the pipeline.${NC}"
echo ""
echo "The management cluster terraform will read IoT outputs from the"
echo "regional state and create the Maestro agent secrets automatically."
echo ""
echo "=============================================================================="
