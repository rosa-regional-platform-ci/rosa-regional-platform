#!/usr/bin/env bash
#
# Build and push the loki-operator Helm OCI chart to a personal registry.
#
# The upstream loki-operator does not publish a Helm chart, only kustomize manifests
# and OLM bundles. This script packages those manifests into a Helm chart and pushes
# it as an OCI artifact so ArgoCD can consume it.
#
# Usage:
#   ./build-chart.sh                    # defaults: version=0.10.0, registry=oci://quay.io/slopezz/loki-operator-chart
#   ./build-chart.sh 0.10.0 quay.io/myuser/loki-operator-chart
#
# Prerequisites:
#   - helm, kubectl (with kustomize built-in), yq (v4+), git
#   - helm registry login quay.io (run once before pushing)
#
# Safe to run multiple times — uses a fresh temp directory each run.

set -euo pipefail

VERSION="${1:-0.10.0}"
REGISTRY="${2:-quay.io/slopezz/loki-operator-chart}"
UPSTREAM_TAG="operator/v${VERSION}"
WORKDIR=$(mktemp -d)

trap "rm -rf ${WORKDIR}" EXIT

# Verify prerequisites
for cmd in helm kubectl yq git; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is required but not found in PATH" >&2
    exit 1
  fi
done

echo "==> Cloning grafana/loki at tag ${UPSTREAM_TAG}..."
git clone --depth 1 --branch "${UPSTREAM_TAG}" https://github.com/grafana/loki.git "${WORKDIR}/loki"

CHART_DIR="${WORKDIR}/chart/loki-operator"
mkdir -p "${CHART_DIR}/templates" "${CHART_DIR}/crds"

echo "==> Writing Chart.yaml..."
cat > "${CHART_DIR}/Chart.yaml" <<EOF
apiVersion: v2
name: loki-operator
description: Loki Operator - packaged from upstream kustomize manifests
type: application
version: ${VERSION}
appVersion: "${VERSION}"
EOF

echo "==> Copying CRDs..."
cp "${WORKDIR}/loki/operator/config/crd/bases/"*.yaml "${CHART_DIR}/crds/"

echo "==> Building kustomize manifests (non-CRD resources)..."
# The kustomize entry point varies by version. Try common paths.
KUSTOMIZE_DIR=""
for candidate in "config/default" "config/overlays/community" "config/manager"; do
  if [[ -f "${WORKDIR}/loki/operator/${candidate}/kustomization.yaml" ]]; then
    KUSTOMIZE_DIR="${WORKDIR}/loki/operator/${candidate}"
    break
  fi
done

if [[ -z "${KUSTOMIZE_DIR}" ]]; then
  echo "WARN: No kustomization.yaml found, falling back to manual manifest assembly" >&2
  # Assemble from individual config directories
  cat "${WORKDIR}/loki/operator/config/rbac/"*.yaml > "${CHART_DIR}/templates/operator.yaml"
  cat "${WORKDIR}/loki/operator/config/manager/"*.yaml >> "${CHART_DIR}/templates/operator.yaml"
else
  echo "    Using kustomize dir: ${KUSTOMIZE_DIR}"
  kubectl kustomize "${KUSTOMIZE_DIR}" \
    | yq 'select(.kind != "CustomResourceDefinition")' \
    > "${CHART_DIR}/templates/operator.yaml"
fi

echo "==> Packaging Helm chart..."
helm package "${CHART_DIR}" --destination "${WORKDIR}"

CHART_FILE="${WORKDIR}/loki-operator-${VERSION}.tgz"
if [[ ! -f "${CHART_FILE}" ]]; then
  echo "ERROR: Expected chart file not found: ${CHART_FILE}" >&2
  exit 1
fi

echo "==> Pushing to oci://${REGISTRY}..."
helm push "${CHART_FILE}" "oci://${REGISTRY}"

echo ""
echo "==> Success!"
echo ""
echo "Chart pushed to: oci://${REGISTRY}/loki-operator:${VERSION}"
echo ""
echo "To use in Chart.yaml:"
echo "  dependencies:"
echo "    - name: loki-operator"
echo "      version: ${VERSION}"
echo "      repository: oci://${REGISTRY}"
