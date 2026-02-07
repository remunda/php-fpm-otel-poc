#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

CLUSTER_NAME="oteltest-local"
NAMESPACE="oteltest-local"
RECREATE=false
DETACHED=false

# Create temporary kubeconfig for k3d
K3D_KUBECONFIG=$(mktemp --suffix=.kubeconfig)
export KUBECONFIG="$K3D_KUBECONFIG"

# Cleanup on exit
cleanup() {
    rm -f "$K3D_KUBECONFIG"
}
trap cleanup EXIT

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--recreate)
            RECREATE=true
            shift
            ;;
        -d|--detached)
            DETACHED=true
            shift
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Usage: $0 [-r|--recreate] [-d|--detached]"
            exit 1
            ;;
    esac
done

echo -e "${GREEN}=== oteltest Local K3D Setup ===${NC}"

# Check if k3d is installed
if ! command -v k3d &> /dev/null; then
    echo -e "${RED}k3d is not installed!${NC}"
    echo "Install it with: curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash"
    exit 1
fi

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}kubectl is not installed!${NC}"
    exit 1
fi

# Check if helm is installed
if ! command -v helm &> /dev/null; then
    echo -e "${RED}helm is not installed!${NC}"
    echo "Install it with: curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 | bash"
    exit 1
fi

# Check helm version (need v3.0.0+)
HELM_VERSION=$(helm version --short 2>/dev/null | grep -oP 'v\d+\.\d+' | head -1 | sed 's/v//')
HELM_MAJOR=$(echo "$HELM_VERSION" | cut -d. -f1)
if [ "$HELM_MAJOR" -lt 3 ]; then
    echo -e "${RED}helm version 3 is required (found v$HELM_VERSION)${NC}"
    echo "Upgrade helm: curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
    exit 1
fi

# Check if kustomize is installed
if ! command -v kustomize &> /dev/null; then
    echo -e "${RED}kustomize is not installed!${NC}"
    echo "Install it with:"
    echo "  curl -L 'https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv5.5.0/kustomize_v5.5.0_linux_amd64.tar.gz' | tar xz"
    echo "  sudo mv kustomize /usr/local/bin/"
    exit 1
fi

# Check if cluster already exists
if k3d cluster list | grep -q "$CLUSTER_NAME"; then
    if [ "$RECREATE" = true ]; then
        echo -e "${YELLOW}Recreating cluster...${NC}"
        k3d cluster delete "$CLUSTER_NAME"
    else
        echo -e "${YELLOW}Cluster '$CLUSTER_NAME' already exists${NC}"
        echo -e "${YELLOW}Using existing cluster${NC}"
        k3d cluster start "$CLUSTER_NAME" 2>/dev/null || true       
    fi
fi

# Create k3d cluster if it doesn't exist
if ! k3d cluster list | grep -q "$CLUSTER_NAME"; then
    echo -e "${GREEN}Creating k3d cluster '$CLUSTER_NAME'...${NC}"
    k3d cluster create "$CLUSTER_NAME" \
        --agents 1 \
        --port "8080:80@loadbalancer" \
        --port "8443:443@loadbalancer" \
        --kubeconfig-update-default=false \
        --wait
       
fi

# Get k3d kubeconfig and fix 0.0.0.0 to 127.0.0.1
echo -e "${GREEN}Loading k3d kubeconfig...${NC}"
k3d kubeconfig get "$CLUSTER_NAME" > "$K3D_KUBECONFIG"

# Set kubectl context
kubectl config use-context "k3d-$CLUSTER_NAME"

# Wait for API server to be ready
echo -e "${YELLOW}Waiting for API server to be ready...${NC}"
for i in {1..30}; do
    if kubectl cluster-info &>/dev/null; then
        echo -e "${GREEN}API server is ready${NC}"
        break
    fi
    if [ $i -eq 30 ]; then
        echo -e "${RED}API server failed to become ready${NC}"
        exit 1
    fi
    sleep 1
done

# Wait for CoreDNS to be ready (required for service discovery)
echo -e "${YELLOW}Waiting for CoreDNS to be ready...${NC}"
for i in {1..60}; do
    if kubectl get pods -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"; then
        echo -e "${GREEN}CoreDNS is ready${NC}"
        break
    fi
    if [ $i -eq 60 ]; then
        echo -e "${RED}CoreDNS failed to become ready${NC}"
        exit 1
    fi
    echo -ne "\r${YELLOW}Waiting for CoreDNS... ($i/60)${NC}"
    sleep 1
done

# Create namespace
echo -e "${GREEN}Creating namespace '$NAMESPACE'...${NC}"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Set namespace as default in context
kubectl config set-context --current --namespace="$NAMESPACE"

# Load API token from environment or .env/.env.local
GRAFANA_API_TOKEN="${GRAFANA_CLOUD_TOKEN:-}"
if [ -z "$GRAFANA_API_TOKEN" ]; then
    if [ -f ".env.local" ]; then
        set -a
        # shellcheck disable=SC1091
        . ./.env.local
        set +a
    fi
    if [ -z "$GRAFANA_CLOUD_TOKEN" ] && [ -f ".env" ]; then
        set -a
        # shellcheck disable=SC1091
        . ./.env
        set +a
    fi
    GRAFANA_API_TOKEN="${GRAFANA_CLOUD_TOKEN:-}"
fi

# Fallback to simple parsing if the files use non-shell syntax
if [ -z "$GRAFANA_API_TOKEN" ]; then
    if [ -f ".env.local" ]; then
        GRAFANA_API_TOKEN=$(grep "^GRAFANA_CLOUD_TOKEN" .env.local | head -1 | cut -d '=' -f2- | tr -d '"' | tr -d "'")
    fi
    if [ -z "$GRAFANA_API_TOKEN" ] && [ -f ".env" ]; then
        GRAFANA_API_TOKEN=$(grep "^GRAFANA_CLOUD_TOKEN" .env | head -1 | cut -d '=' -f2- | tr -d '"' | tr -d "'")
    fi
fi

if [ -z "$GRAFANA_API_TOKEN" ]; then
    echo -e "${YELLOW}Warning: GRAFANA_CLOUD_TOKEN not found in .env or .env.local${NC}"
    echo -e "${YELLOW}Using mock token for local testing${NC}"
    GRAFANA_API_TOKEN="mock-api-token-for-local-testing"
fi

# Create Grafana Cloud credentials secret
echo -e "${GREEN}Creating Grafana Cloud credentials...${NC}"
kubectl create secret generic grafana-cloud-credentials \
    --from-literal=api-token="$GRAFANA_API_TOKEN" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

# Add Grafana Helm repository
echo -e "${GREEN}Adding Grafana Helm repository...${NC}"
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update

# Deploy Grafana Alloy using kustomize with Helm support
echo -e "${GREEN}Deploying Grafana Alloy...${NC}"
kustomize build --enable-helm orchestration/kubernetes/grafana/overlays/local | kubectl apply -n "$NAMESPACE" -f -

# Wait for Alloy to be ready
echo -e "${YELLOW}Waiting for Alloy to be ready...${NC}"
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=alloy -n "$NAMESPACE" --timeout=3s || true

# Build and deploy the PHP application
echo -e "${GREEN}Building PHP application Docker image...${NC}"
docker build -f Dockerfile.poc -t oteltest-app:latest .

echo -e "${GREEN}Importing image into k3d cluster...${NC}"
k3d image import oteltest-app:latest -c "$CLUSTER_NAME"

echo -e "${GREEN}Deploying PHP application...${NC}"
kubectl apply -f orchestration/kubernetes/app/ -n "$NAMESPACE"

# Wait for app to be ready
echo -e "${YELLOW}Waiting for PHP app to be ready...${NC}"
kubectl wait --for=condition=ready pod -l app=webserver-php-fpm -n "$NAMESPACE" --timeout=120s || true

echo ""
echo -e "${GREEN}=== K3D Cluster is ready! ===${NC}"
echo ""
echo "Cluster name: $CLUSTER_NAME"
echo "Namespace: $NAMESPACE"
echo ""
echo -e "${GREEN}=== Quick commands ===${NC}"
echo ""
echo -e "${YELLOW}Port-forward app (test endpoint):${NC}"
echo "  kubectl port-forward svc/php-fpm 8080:8080 -n $NAMESPACE"
echo "  curl http://localhost:8080/api/test"
echo ""
echo -e "${YELLOW}Port-forward Alloy UI:${NC}"
echo "  kubectl port-forward svc/grafana-alloy 12345:12345 -n $NAMESPACE"
echo "  open http://localhost:12345"
echo ""
echo -e "${YELLOW}Change PHP-FPM workers (e.g. to 1):${NC}"
echo "  kubectl set env deployment/php-app PHP_FPM_MAX_CHILDREN=1 -n $NAMESPACE"
echo ""
echo -e "${YELLOW}Change load-generator interval (e.g. 0.1s = 10 req/s):${NC}"
echo "  kubectl set env deployment/load-generator LOAD_INTERVAL=0.1 -n $NAMESPACE"
echo ""
echo -e "${YELLOW}Watch logs:${NC}"
echo "  kubectl logs -f deployment/php-app -c php-fpm -n $NAMESPACE"
echo "  kubectl logs -f deployment/load-generator -n $NAMESPACE"
echo ""
echo -e "${YELLOW}To run kubectl commands against the cluster:${NC}"
echo "  ./k3dctl.sh $CLUSTER_NAME    # Start a new shell with k3d kubeconfig"
echo ""
echo -e "${GREEN}Stop cluster:${NC}"
echo "  k3d cluster stop $CLUSTER_NAME"
echo ""
echo -e "${GREEN}Delete cluster:${NC}"
echo "  k3d cluster delete $CLUSTER_NAME"
echo ""

# Launch k3dctl.sh if not in detached mode
if [ "$DETACHED" = false ]; then
    echo -e "${GREEN}Starting k3dctl.sh shell...${NC}"
    echo -e "${YELLOW}(Use -d flag to skip this step)${NC}"
    echo ""
    exec "$(dirname "$0")/k3dctl.sh" "$CLUSTER_NAME" -ns "$NAMESPACE"
fi
