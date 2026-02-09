#!/bin/bash
# Starts a new shell with kubeconfig set to k3d clusters
# Usage: ./k3d-shell.sh [cluster-name]
#   without argument - uses all k3d clusters
#   with argument    - uses only the specified cluster

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

DEFAULT_NAMESPACE=""
CLUSTER_ARG=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -ns|--namespace)
            DEFAULT_NAMESPACE="$2"
            shift 2
            ;;
        *)
            if [ -z "$CLUSTER_ARG" ]; then
                CLUSTER_ARG="$1"
            else
                echo -e "${RED}Unknown option: $1${NC}"
                echo "Usage: $0 [cluster-name] [-ns|--namespace <namespace>]"
                exit 1
            fi
            shift
            ;;
    esac
done

# Find available k3d clusters (without jq - parse text output)
CLUSTERS=$(k3d cluster list --no-headers 2>/dev/null | awk '{print $1}')

if [ -z "$CLUSTERS" ]; then
    echo -e "${RED}No k3d clusters found!${NC}"
    echo "Create a cluster using: k3d cluster create <name>"
    exit 1
fi

# If cluster argument is provided, use only that cluster
if [ -n "$CLUSTER_ARG" ]; then
    if echo "$CLUSTERS" | grep -q "^$CLUSTER_ARG$"; then
        CLUSTERS="$CLUSTER_ARG"
    else
        echo -e "${RED}Cluster '$CLUSTER_ARG' not found!${NC}"
        echo -e "${YELLOW}Available clusters:${NC}"
        echo "$CLUSTERS" | sed 's/^/  - /'
        exit 1
    fi
fi

# Create temporary kubeconfig
K3D_KUBECONFIG=$(mktemp --suffix=.kubeconfig)

echo -e "${YELLOW}Generating kubeconfig for clusters:${NC}"
echo "$CLUSTERS" | sed 's/^/  - /'

# Merge kubeconfig from all clusters
KUBECONFIG_LIST=""
for cluster in $CLUSTERS; do
    TEMP_CONFIG=$(mktemp)
    k3d kubeconfig get "$cluster" > "$TEMP_CONFIG"
   
    if [ -z "$KUBECONFIG_LIST" ]; then
        KUBECONFIG_LIST="$TEMP_CONFIG"
    else
        KUBECONFIG_LIST="$KUBECONFIG_LIST:$TEMP_CONFIG"
    fi
done

# Merge all configurations into one file
KUBECONFIG="$KUBECONFIG_LIST" kubectl config view --flatten > "$K3D_KUBECONFIG"

# Clean up temporary files
for f in $(echo "$KUBECONFIG_LIST" | tr ':' ' '); do
    rm -f "$f"
done

# Set first cluster as default context
FIRST_CLUSTER=$(echo "$CLUSTERS" | head -1)
KUBECONFIG="$K3D_KUBECONFIG" kubectl config use-context "k3d-$FIRST_CLUSTER" >/dev/null 2>&1

# Set default namespace if specified
if [ -n "$DEFAULT_NAMESPACE" ]; then
    KUBECONFIG="$K3D_KUBECONFIG" kubectl config set-context --current --namespace="$DEFAULT_NAMESPACE" >/dev/null 2>&1
    echo -e "${GREEN}Kubeconfig created: $K3D_KUBECONFIG${NC}"
    echo -e "${GREEN}Default context: k3d-$FIRST_CLUSTER${NC}"
    echo -e "${GREEN}Default namespace: $DEFAULT_NAMESPACE${NC}"
else
    echo -e "${GREEN}Kubeconfig created: $K3D_KUBECONFIG${NC}"
    echo -e "${GREEN}Default context: k3d-$FIRST_CLUSTER${NC}"
fi
echo ""
echo -e "${YELLOW}Starting new shell...${NC}"
echo -e "${YELLOW}To exit, type 'exit' or press Ctrl+D${NC}"
echo ""

# Start new shell with KUBECONFIG set
export KUBECONFIG="$K3D_KUBECONFIG"
export K3D_SHELL="1"
export PS1_PREFIX="(k3d) "

# Cleanup on exit
cleanup() {
    rm -f "$K3D_KUBECONFIG"
    echo -e "${GREEN}Kubeconfig deleted.${NC}"
}
trap cleanup EXIT

# Start interactive shell
if [ -n "$ZSH_VERSION" ] || [ "$SHELL" = "/bin/zsh" ] || [ "$SHELL" = "/usr/bin/zsh" ]; then
    # For zsh - add prefix to prompt
    ZDOTDIR_TEMP=$(mktemp -d)
    if [ -f "$HOME/.zshrc" ]; then
        cp "$HOME/.zshrc" "$ZDOTDIR_TEMP/.zshrc"
    fi
    echo 'PROMPT="(k3d) $PROMPT"' >> "$ZDOTDIR_TEMP/.zshrc"
    ZDOTDIR="$ZDOTDIR_TEMP" zsh -i
    rm -rf "$ZDOTDIR_TEMP"
else
    # For bash
    bash --rcfile <(echo 'source ~/.bashrc 2>/dev/null; PS1="(k3d) $PS1"') -i
fi
