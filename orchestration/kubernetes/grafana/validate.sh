#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/base/config.alloy"

echo "🔍 Validating Grafana Alloy configuration..."
echo "Config file: $CONFIG_FILE"
echo ""

# Get the helm chart version to determine the Alloy version
CHART_VERSION=$(grep "version:" "$SCRIPT_DIR/base/kustomization.yaml" | head -1 | awk '{print $2}')
echo "📦 Helm chart version: $CHART_VERSION"

# Map chart version to app version (from helm search)
# Chart 1.5.1 = App v1.12.1
ALLOY_VERSION="v1.12.1"
echo "🏷️  Alloy version: $ALLOY_VERSION"
echo ""

# Run validation
docker run --rm \
  -v "$SCRIPT_DIR/base:/workspace" \
  "grafana/alloy:$ALLOY_VERSION" \
  validate --stability.level=experimental /workspace/config.alloy

echo ""
echo "✅ Configuration is valid!"
