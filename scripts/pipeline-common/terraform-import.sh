#!/usr/bin/env bash
#
# terraform-import.sh - Idempotent Terraform import helper for automated pipelines
#
# Provides:
#   import_if_needed <terraform-address> <aws-resource-id>
#   tf_state_value   <terraform-address> <jq-expression>
#   tf_import_summary
#
# Behavior:
#   - Resource already in TF state: skip (no AWS API call, ~10ms)
#   - Resource exists in AWS but not in state: import into state
#   - Resource does not exist in AWS (fresh env): skip (expected)
#   - Unexpected error (permissions, state lock, API failure): FAIL pipeline
#
# Error classification:
#   When terraform import exits non-zero, stderr is inspected:
#   - Matches known "not found" patterns -> normal on fresh environments
#   - Anything else -> real failure, pipeline exits non-zero
#
# Usage:
#   source scripts/pipeline-common/terraform-import.sh
#   import_if_needed 'module.foo.aws_bar.baz' 'the-aws-resource-id'
#   tf_import_summary
#
# Dependencies: jq (pre-installed in CodeBuild via terraform-install.sh)
#
# Lifecycle: Once all environments have run at least one successful apply,
# import_if_needed calls become permanent no-ops. Entries can be removed
# from imports.sh, or left in place as documentation of what was migrated.

set -uo pipefail

_TF_IMPORT_COUNT=0
_TF_IMPORT_SKIPPED=0
_TF_IMPORT_NOT_FOUND=0
_TF_IMPORT_FAILED=0

# Patterns in terraform import stderr that indicate "resource doesn't exist in AWS".
# These are expected on fresh environments and should NOT fail the pipeline.
_TF_IMPORT_NOT_FOUND_PATTERNS=(
    "ResourceNotFoundException"
    "does not exist"
    "NoSuchEntity"
    "NotFoundException"
    "404"
    "Cannot import non-existent"
)

# import_if_needed <terraform-address> <aws-resource-id>
#
# Idempotently imports an AWS resource into Terraform state.
# Safe to call on any environment — handles all outcomes gracefully.
import_if_needed() {
    local ADDR="$1"
    local ID="$2"

    # Fast path: already in state (no AWS API call, ~10ms)
    if terraform state show "$ADDR" &>/dev/null; then
        echo "  [skip] $ADDR — already in state"
        ((_TF_IMPORT_SKIPPED++)) || true
        return 0
    fi

    # Attempt import, capturing stderr for error classification
    local IMPORT_STDERR
    IMPORT_STDERR=$(mktemp)
    if terraform import "$ADDR" "$ID" 2>"$IMPORT_STDERR"; then
        echo "  [imported] $ADDR <- $ID"
        ((_TF_IMPORT_COUNT++)) || true
        rm -f "$IMPORT_STDERR"
        return 0
    fi

    # Import failed — classify the error
    local ERR_MSG
    ERR_MSG=$(cat "$IMPORT_STDERR")
    rm -f "$IMPORT_STDERR"

    for pattern in "${_TF_IMPORT_NOT_FOUND_PATTERNS[@]}"; do
        if [[ "$ERR_MSG" == *"$pattern"* ]]; then
            echo "  [not-found] $ADDR — resource does not exist in AWS (expected on fresh env)"
            ((_TF_IMPORT_NOT_FOUND++)) || true
            return 0
        fi
    done

    # Unrecognized error — real failure
    echo "  [FAILED] $ADDR <- $ID"
    echo "    Error: $ERR_MSG" >&2
    ((_TF_IMPORT_FAILED++)) || true
    return 1
}

# tf_state_value <terraform-address> <attribute-name>
#
# Extract a resource attribute from Terraform state using terraform state pull (JSON).
# Returns empty string (exit 0) if resource is not in state or attribute is missing.
#
# The second argument is a jq-style path for backward compat (e.g. '.values.id')
# but only the final attribute name is used (e.g. 'id').
#
# Example: BROKER_ID=$(tf_state_value 'module.foo.aws_mq_broker.bar' '.values.id')
tf_state_value() {
    local ADDR="$1"
    local JQ_EXPR="$2"

    # Extract simple attribute name from jq expression: .values.id -> id
    local ATTR="${JQ_EXPR#.values.}"

    # Pull full state JSON and filter by address + attribute
    terraform state pull 2>/dev/null | jq -r --arg addr "$ADDR" --arg attr "$ATTR" '
        [.resources[] |
         select(
           ((if .module then .module + "." else "" end) + .type + "." + .name) == $addr
         )
        ] | first | .instances[0].attributes[$attr] // empty
    ' 2>/dev/null || true
}

# tf_import_summary
#
# Print summary and exit non-zero if any imports failed with unexpected errors.
# MUST be called at the end of every imports.sh — acts as the pipeline gate.
tf_import_summary() {
    echo ""
    echo "=== Import summary ==="
    echo "  Imported:          ${_TF_IMPORT_COUNT}"
    echo "  Already in state:  ${_TF_IMPORT_SKIPPED}"
    echo "  Not found (fresh): ${_TF_IMPORT_NOT_FOUND}"
    echo "  FAILED:            ${_TF_IMPORT_FAILED}"
    echo "======================"
    if [ "${_TF_IMPORT_FAILED}" -gt 0 ]; then
        echo "ERROR: ${_TF_IMPORT_FAILED} import(s) failed with unexpected errors — aborting before apply" >&2
        exit 1
    fi
}
