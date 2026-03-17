#!/usr/bin/env bash
# Provision regional and management cluster pipelines from deploy/ directory structure.
#
# Reads region and management cluster configs from deploy/<environment>/<region>/terraform/
# and runs terraform to create/update the corresponding CodePipeline pipelines.
#
# Required environment variables:
#   ENVIRONMENT          - Target environment (e.g., staging, production)
#   GITHUB_REPOSITORY    - GitHub repository in owner/name format (e.g., 'octocat/hello-world')
#   GITHUB_BRANCH        - GitHub branch to track
#   GITHUB_CONNECTION_ARN - CodeStar connection ARN
#   PLATFORM_IMAGE       - Platform container image URI for CodeBuild projects

set -euo pipefail
trap 'echo "FAILED: line $LINENO, exit code $?" >&2' ERR

echo "=========================================="
echo "Provisioning Pipelines"
echo "Build #${CODEBUILD_BUILD_NUMBER:-?} | ${CODEBUILD_BUILD_ID:-unknown}"
echo "=========================================="

# Get central account ID for state bucket
CENTRAL_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TF_STATE_BUCKET="terraform-state-${CENTRAL_ACCOUNT_ID}"

# Save central credentials for account switching
_CENTRAL_AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
_CENTRAL_AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
_CENTRAL_AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"

# Track which target accounts have had state buckets bootstrapped (avoid duplicates)
BOOTSTRAPPED_ACCOUNTS=""

# Bootstrap state bucket in a target account (idempotent)
bootstrap_target_state_bucket() {
    local target_account_id="$1"
    local target_region="$2"

    # Skip if already bootstrapped this account in this run
    if echo "$BOOTSTRAPPED_ACCOUNTS" | grep -q "|${target_account_id}|"; then
        echo "State bucket already bootstrapped for account $target_account_id (skipping)"
        return 0
    fi

    echo "Bootstrapping state bucket in target account $target_account_id..."

    if [ "$target_account_id" = "$CENTRAL_ACCOUNT_ID" ]; then
        # Same account - run bootstrap directly
        ./scripts/bootstrap-state.sh "$target_region"
    else
        # Cross-account - assume role first
        local creds
        if ! creds=$(aws sts assume-role \
            --role-arn "arn:aws:iam::${target_account_id}:role/OrganizationAccountAccessRole" \
            --role-session-name "bootstrap-state-${target_account_id}" \
            --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
            --output text 2>&1); then
            echo "ERROR: Failed to assume role in account $target_account_id for state bootstrap"
            echo "Error: $creds"
            return 1
        fi

        # Run bootstrap with target credentials
        AWS_ACCESS_KEY_ID=$(echo "$creds" | awk '{print $1}') \
        AWS_SECRET_ACCESS_KEY=$(echo "$creds" | awk '{print $2}') \
        AWS_SESSION_TOKEN=$(echo "$creds" | awk '{print $3}') \
        ./scripts/bootstrap-state.sh "$target_region"
    fi

    BOOTSTRAPPED_ACCOUNTS="${BOOTSTRAPPED_ACCOUNTS}|${target_account_id}|"
    echo "State bucket ready in account $target_account_id"
    echo ""
}

# Determine which environment to process (prefer existing, fall back to TARGET_ENVIRONMENT, then staging)
ENVIRONMENT="${ENVIRONMENT:-${TARGET_ENVIRONMENT:-staging}}"

# Validate and sanitize ENVIRONMENT to prevent path traversal and injection
if [[ -z "$ENVIRONMENT" ]]; then
    echo "❌ ERROR: ENVIRONMENT is empty" >&2
    exit 1
fi
if [[ "$ENVIRONMENT" == *"/"* ]]; then
    echo "❌ ERROR: ENVIRONMENT contains invalid character '/': $ENVIRONMENT" >&2
    exit 1
fi
if [[ "$ENVIRONMENT" == *".."* ]]; then
    echo "❌ ERROR: ENVIRONMENT contains path traversal sequence '..': $ENVIRONMENT" >&2
    exit 1
fi
if [[ "$ENVIRONMENT" =~ [[:space:]] ]]; then
    echo "❌ ERROR: ENVIRONMENT contains whitespace: $ENVIRONMENT" >&2
    exit 1
fi
if [[ ! "$ENVIRONMENT" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "❌ ERROR: ENVIRONMENT contains invalid characters: $ENVIRONMENT" >&2
    echo "   Only alphanumeric, dot (.), underscore (_), and hyphen (-) are allowed" >&2
    exit 1
fi

# Read environment config
ENV_JSON="deploy/${ENVIRONMENT}/environment.json"
if [ ! -f "$ENV_JSON" ]; then
    echo "ERROR: Environment config not found: $ENV_JSON" >&2
    exit 1
fi

# Try to read tf_state_region from environment.json
TF_STATE_REGION=$(jq -r '.tf_state_region // empty' "$ENV_JSON" 2>/dev/null || echo "")

# If not found in config, try to detect from bucket location
if [ -z "$TF_STATE_REGION" ]; then
    BUCKET_REGION=$(aws s3api get-bucket-location --bucket "$TF_STATE_BUCKET" --region us-east-1 --query LocationConstraint --output text 2>/dev/null || echo "")
    if [ "$BUCKET_REGION" == "None" ] || [ "$BUCKET_REGION" == "null" ] || [ -z "$BUCKET_REGION" ]; then
        TF_STATE_REGION="us-east-1"
    else
        TF_STATE_REGION="$BUCKET_REGION"
    fi
fi

echo "Using state bucket: $TF_STATE_BUCKET"
echo "Using state bucket region: $TF_STATE_REGION"
echo "Using lockfile-based state locking"

# Helper function: Retry terraform apply with exponential backoff
# Usage: retry_terraform_apply "${TF_ARGS[@]}"
retry_terraform_apply() {
    local max_attempts=3
    local attempt=1
    local wait_time=30

    while [ $attempt -le $max_attempts ]; do
        echo "📝 Attempt $attempt/$max_attempts: Running terraform apply..."

        if terraform apply -auto-approve "$@"; then
            echo "✅ Terraform apply succeeded"
            return 0
        else
            if [ $attempt -lt $max_attempts ]; then
                echo "⚠️  Attempt $attempt failed, waiting ${wait_time}s before retry..."
                sleep $wait_time
                wait_time=$((wait_time * 2))  # Exponential backoff
                attempt=$((attempt + 1))
            else
                echo "❌ All $max_attempts attempts failed"
                return 1
            fi
        fi
    done
}

# Helper function: Resolve SSM parameter if value starts with "ssm://"
resolve_ssm_param() {
    local value="$1"
    local region="${2:-${AWS_REGION}}"  # Optional region parameter, defaults to AWS_REGION
    if [[ "$value" == ssm://* ]]; then
        local param_name="${value#ssm://}"
        echo "Resolving SSM parameter: $param_name in region ${region}" >&2
        aws ssm get-parameter \
            --name "$param_name" \
            --with-decryption \
            --query 'Parameter.Value' \
            --output text \
            --region "${region}"
    else
        echo "$value"
    fi
}

# Helper function: Trigger pipeline destruction
# Arguments: pipeline_type (regional/management)
destroy_pipeline() {
    local pipeline_type="$1"
    
    echo "⚠️  Processing DELETE request for $pipeline_type pipeline..."

    # Note: We skip triggering infrastructure destruction via CodeBuild because
    # CodeBuild projects with CODEPIPELINE artifacts can't be started directly.
    # The actual infrastructure (EKS cluster, VPC, etc.) should be destroyed
    # separately using the pipeline's destroy mode or manual cleanup.

    echo "⚠️  WARNING: This will only destroy the pipeline resources (CodePipeline, CodeBuild, S3)."
    echo "   The actual infrastructure (EKS cluster, VPC, etc.) must be destroyed separately."
    echo "   To destroy infrastructure, trigger the pipeline with IS_DESTROY=true or use manual cleanup."
    
    # Destroy the pipeline resources
    echo "Destroying pipeline resources (CodePipeline, CodeBuild, S3)..."
    if terraform destroy -auto-approve "${TF_ARGS[@]}"; then
        echo "✅ Pipeline resources destroyed."
        return 0
    else
        echo "❌ Failed to destroy pipeline resources."
        return 1
    fi
}

# --- BEGIN TEMPORARY CI HACK (remove when e2e uses a dedicated config with per-cluster delete flags) ---
# FORCE_DELETE_ALL_PIPELINES=true force-sets DELETE_FLAG=true for ALL clusters, bypassing
# per-cluster config. This exists solely to let e2e teardown destroy everything without a
# custom config. Passed as a CodePipeline variable from ci/e2e.sh.
FORCE_DELETE_ALL_PIPELINES="${FORCE_DELETE_ALL_PIPELINES:-false}"
echo "Force delete all pipelines: $FORCE_DELETE_ALL_PIPELINES"
# --- END TEMPORARY CI HACK ---

echo "Processing environment: $ENVIRONMENT"
echo ""

# Validate region_definitions exist in environment.json
REGION_COUNT=$(jq -r '.region_definitions | length' "$ENV_JSON")
if [ "$REGION_COUNT" -eq 0 ]; then
    echo "❌ ERROR: No region_definitions found in $ENV_JSON" >&2
    echo "   Ensure config.yaml has regions for environment '${ENVIRONMENT}' and run scripts/render.py" >&2
    exit 1
fi

echo "Found ${REGION_COUNT} region(s) in environment '${ENVIRONMENT}'"
echo ""

# =============================================================================
# DNS Environment Zone (optional)
#
# When domain is configured in environment.json, create the environment
# hosted zone (e.g. int0.rosa.devshift.net) in the central account before
# processing regions. The zone ID is passed to regional pipelines for NS delegation.
# =============================================================================

ENVIRONMENT_DOMAIN=""
ENVIRONMENT_HOSTED_ZONE_ID=""

ENVIRONMENT_DOMAIN=$(jq -r '.domain // empty' "deploy/${ENVIRONMENT}/environment.json" 2>/dev/null || echo "")

if [ -n "$ENVIRONMENT_DOMAIN" ]; then
    echo "=========================================="
    echo "Provisioning DNS Environment Zone: $ENVIRONMENT_DOMAIN"
    echo "=========================================="

    cd terraform/config/dns-environment-zone

    terraform init \
        -reconfigure \
        -backend-config="bucket=$TF_STATE_BUCKET" \
        -backend-config="key=dns/environment-zone-${ENVIRONMENT}.tfstate" \
        -backend-config="region=$TF_STATE_REGION" \
        -backend-config="use_lockfile=true"

    if retry_terraform_apply \
        -var="environment_domain=${ENVIRONMENT_DOMAIN}" \
        -var="environment=${ENVIRONMENT}"; then
        ENVIRONMENT_HOSTED_ZONE_ID=$(terraform output -raw zone_id)
        echo "✅ Environment zone created: $ENVIRONMENT_DOMAIN (zone ID: $ENVIRONMENT_HOSTED_ZONE_ID)"
    else
        echo "❌ Failed to create environment zone: $ENVIRONMENT_DOMAIN"
        exit 1
    fi

    cd ../../..
    echo ""
fi

# Process each region from environment.json
for REGION_DEPLOYMENT in $(jq -r '.region_definitions | keys[]' "$ENV_JSON"); do

    echo "=========================================="
    echo "Processing: $ENVIRONMENT / $REGION_DEPLOYMENT"
    echo "=========================================="

    # Extract regional configuration from environment.json
    AWS_REGION="$REGION_DEPLOYMENT"
    TARGET_ACCOUNT_ID=$(jq -r ".region_definitions[\"$REGION_DEPLOYMENT\"].account_id // \"\"" "$ENV_JSON")
    TARGET_ACCOUNT_ID=$(resolve_ssm_param "$TARGET_ACCOUNT_ID" "$AWS_REGION")
    REGIONAL_ID=$(jq -r ".region_definitions[\"$REGION_DEPLOYMENT\"].regional_id // \"\"" "$ENV_JSON")

    DELETE_FLAG=$(jq -r ".region_definitions[\"$REGION_DEPLOYMENT\"].delete_pipeline // false" "$ENV_JSON")

    # TEMPORARY CI HACK (see top of file)
    [ "$FORCE_DELETE_ALL_PIPELINES" == "true" ] && DELETE_FLAG="true"

    echo "  AWS Region: $AWS_REGION"
    [ -n "$TARGET_ACCOUNT_ID" ] && echo "  Target Account ID: $TARGET_ACCOUNT_ID"
    [ -n "$REGIONAL_ID" ] && echo "  Regional ID: $REGIONAL_ID"
    echo "  Delete Flag: $DELETE_FLAG"

    # Validate TARGET_ACCOUNT_ID before using it
    if [[ -z "$TARGET_ACCOUNT_ID" ]]; then
        echo "❌ ERROR: TARGET_ACCOUNT_ID (account_id) must be provided for region ${AWS_REGION}"
        echo "   Set account_id in your regional config (either direct account ID or ssm:///path/to/param)"
        exit 1
    fi

    # Bootstrap state bucket in target account (idempotent)
    bootstrap_target_state_bucket "$TARGET_ACCOUNT_ID" "$AWS_REGION"

    echo "Processing Regional Cluster Pipeline for ${ENVIRONMENT}-${REGION_DEPLOYMENT}..."

    cd terraform/config/pipeline-regional-cluster

    terraform init \
        -reconfigure \
        -backend-config="bucket=$TF_STATE_BUCKET" \
        -backend-config="key=pipelines/regional-${ENVIRONMENT}-${REGION_DEPLOYMENT}-${REGIONAL_ID}.tfstate" \
        -backend-config="region=$TF_STATE_REGION" \
        -backend-config="use_lockfile=true"

    # Build terraform apply command with variables (array for safe expansion)
    TF_ARGS=(
        -var="github_repository=${GITHUB_REPOSITORY}"
        -var="github_branch=${GITHUB_BRANCH}"
        -var="region=${AWS_REGION}"
    )
    [ -n "$GITHUB_CONNECTION_ARN" ] && TF_ARGS+=( -var="github_connection_arn=${GITHUB_CONNECTION_ARN}" )
    [ -n "$TARGET_ACCOUNT_ID" ] && TF_ARGS+=( -var="target_account_id=${TARGET_ACCOUNT_ID}" )
    [ -n "$AWS_REGION" ] && TF_ARGS+=( -var="target_region=${AWS_REGION}" )
    [ -n "$REGIONAL_ID" ] && TF_ARGS+=( -var="regional_id=${REGIONAL_ID}" )
    [ -n "$ENVIRONMENT" ] && TF_ARGS+=( -var="target_environment=${ENVIRONMENT}" )
    # Repository URL and branch for cluster configuration
    TF_ARGS+=(
        -var="repository_url=https://github.com/${GITHUB_REPOSITORY}.git"
        -var="repository_branch=${GITHUB_BRANCH}"
        -var="codebuild_image=${PLATFORM_IMAGE}"
    )
    # DNS configuration (optional)
    [ -n "$ENVIRONMENT_HOSTED_ZONE_ID" ] && TF_ARGS+=( -var="environment_hosted_zone_id=${ENVIRONMENT_HOSTED_ZONE_ID}" )

    if [ "$DELETE_FLAG" == "true" ]; then
        if destroy_pipeline "regional"; then
            cd ../../..
            echo "✅ Regional pipeline cleanup complete for ${ENVIRONMENT}-${REGION_DEPLOYMENT}"
        else
            cd ../../..
            echo "❌ Failed to destroy regional pipeline for ${ENVIRONMENT}-${REGION_DEPLOYMENT}"
            echo "   Destroy failure requires manual intervention. Aborting."
            exit 1
        fi
    else
        # Apply with retry logic
        if retry_terraform_apply "${TF_ARGS[@]}"; then
            cd ../../..
            echo "✅ Regional pipeline created for ${ENVIRONMENT}-${REGION_DEPLOYMENT}"
        else
            cd ../../..
            echo "❌ Failed to create regional pipeline for ${ENVIRONMENT}-${REGION_DEPLOYMENT} after retries"
            echo "⏭️  Continuing with next region..."
            continue
        fi
    fi

    # Process management clusters from environment.json
    MC_COUNT=$(jq -r ".region_definitions[\"$REGION_DEPLOYMENT\"].management_clusters | length" "$ENV_JSON")
    if [ "$MC_COUNT" -gt 0 ]; then
        echo "Processing $MC_COUNT management cluster(s) in ${ENVIRONMENT}-${REGION_DEPLOYMENT}..."

        for MC_ID in $(jq -r ".region_definitions[\"$REGION_DEPLOYMENT\"].management_clusters | keys[]" "$ENV_JSON"); do

            echo "Found management cluster config: $MC_ID"

            MC_ACCOUNT_ID=$(jq -r ".region_definitions[\"$REGION_DEPLOYMENT\"].management_clusters[\"$MC_ID\"].account_id // \"\"" "$ENV_JSON")
            MC_ACCOUNT_ID=$(resolve_ssm_param "$MC_ACCOUNT_ID" "$AWS_REGION")
            MANAGEMENT_ID="$MC_ID"

            MC_DELETE_FLAG=$(jq -r ".region_definitions[\"$REGION_DEPLOYMENT\"].management_clusters[\"$MC_ID\"].delete_pipeline // false" "$ENV_JSON")

            # TEMPORARY CI HACK (see top of file)
            [ "$FORCE_DELETE_ALL_PIPELINES" == "true" ] && MC_DELETE_FLAG="true"

            echo "  AWS Region: $AWS_REGION"
            [ -n "$MC_ACCOUNT_ID" ] && echo "  Target Account ID: $MC_ACCOUNT_ID"
            [ -n "$MANAGEMENT_ID" ] && echo "  Management ID: $MANAGEMENT_ID"
            echo "  Delete Flag: $MC_DELETE_FLAG"

            # Validate MC_ACCOUNT_ID before using it
            if [[ -z "$MC_ACCOUNT_ID" ]]; then
                echo "❌ ERROR: account_id must be provided for management cluster ${MC_ID}"
                echo "   Set account_id in your management cluster config (either direct account ID or ssm:///path/to/param)"
                exit 1
            fi

            # Bootstrap state bucket in MC target account (idempotent)
            bootstrap_target_state_bucket "$MC_ACCOUNT_ID" "$AWS_REGION"

            echo "Processing Management Cluster Pipeline for $MC_ID in ${ENVIRONMENT}-${REGION_DEPLOYMENT}..."

            cd terraform/config/pipeline-management-cluster

            terraform init \
                -reconfigure \
                -backend-config="bucket=$TF_STATE_BUCKET" \
                -backend-config="key=pipelines/management-${ENVIRONMENT}-${REGION_DEPLOYMENT}-${MC_ID}.tfstate" \
                -backend-config="region=$TF_STATE_REGION" \
                -backend-config="use_lockfile=true"

            # Build terraform apply command with variables (array for safe expansion)
            TF_ARGS=(
                -var="github_repository=${GITHUB_REPOSITORY}"
                -var="github_branch=${GITHUB_BRANCH}"
                -var="region=${AWS_REGION}"
            )
            [ -n "$GITHUB_CONNECTION_ARN" ] && TF_ARGS+=( -var="github_connection_arn=${GITHUB_CONNECTION_ARN}" )
            [ -n "$MC_ACCOUNT_ID" ] && TF_ARGS+=( -var="target_account_id=${MC_ACCOUNT_ID}" )
            [ -n "$AWS_REGION" ] && TF_ARGS+=( -var="target_region=${AWS_REGION}" )
            [ -n "$MANAGEMENT_ID" ] && TF_ARGS+=( -var="management_id=${MANAGEMENT_ID}" )
            [ -n "$ENVIRONMENT" ] && TF_ARGS+=( -var="target_environment=${ENVIRONMENT}" )
            # Repository URL and branch for cluster configuration
            TF_ARGS+=(
                -var="repository_url=https://github.com/${GITHUB_REPOSITORY}.git"
                -var="repository_branch=${GITHUB_BRANCH}"
                -var="codebuild_image=${PLATFORM_IMAGE}"
            )

            if [ "$MC_DELETE_FLAG" == "true" ]; then
                if destroy_pipeline "management"; then
                    cd ../../..
                    echo "✅ Management pipeline cleanup complete for $MC_ID"
                else
                    cd ../../..
                    echo "❌ Failed to destroy management pipeline for $MC_ID"
                    echo "   Destroy failure requires manual intervention. Aborting."
                    exit 1
                fi
            else
                # Apply with retry logic
                if retry_terraform_apply "${TF_ARGS[@]}"; then
                    cd ../../..
                    echo "✅ Management pipeline created for $MC_ID in ${ENVIRONMENT}-${REGION_DEPLOYMENT}"
                else
                    cd ../../..
                    echo "❌ Failed to create management pipeline for $MC_ID after retries"
                    echo "⏭️  Continuing with next management cluster..."
                    continue
                fi
            fi
        done
    else
        echo "No management clusters configured for $REGION_DEPLOYMENT, skipping management pipelines..."
    fi

    echo ""
done
