#!/bin/bash
#
# Script pro update config.alloy na produkci bez CI pipeline
# Použití: ./update-alloy-config-prod.sh
#
# Používá Kustomize pro generování ConfigMap, aby byl výstup
# identický s tím, co generuje CI pipeline.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/base/config.alloy"
KUSTOMIZE_DIR="${SCRIPT_DIR}/base"
CONFIGMAP_NAME="alloy-config"
STATEFULSET_NAME="grafana-alloy"

# Barvy pro výstup
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== Grafana Alloy Config Update (Production) ===${NC}"
echo ""

# Kontrola, že existuje config soubor
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}ERROR: Config file not found: ${CONFIG_FILE}${NC}"
    exit 1
fi

# Kontrola kubectl kontextu
CURRENT_CONTEXT=$(kubectl config current-context)
echo -e "Current kubectl context: ${YELLOW}${CURRENT_CONTEXT}${NC}"
echo ""

# Bezpečnostní kontrola
read -p "Are you sure you want to update Alloy config on PRODUCTION? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo -e "${RED}Aborted.${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}Step 1: Generating and applying ConfigMap via Kustomize...${NC}"

# Použití Kustomize pro generování a aplikaci POUZE ConfigMap
# (stejně jako CI pipeline, ale aplikujeme jen ConfigMap, ne celý stack)
cd "${KUSTOMIZE_DIR}"

if command -v yq &> /dev/null; then
    # Preferovaná metoda: yq pro filtrování YAML
    kubectl kustomize . | \
        yq 'select(.kind == "ConfigMap" and .metadata.name == "alloy-config")' | \
        kubectl apply -f -
else
    # Fallback: ruční vytvoření ConfigMap (funkčně ekvivalentní)
    # Kustomize configMapGenerator vytváří stejnou strukturu jako kubectl create configmap --from-file
    echo -e "${YELLOW}yq not found, using direct ConfigMap creation...${NC}"
    kubectl create configmap "${CONFIGMAP_NAME}" \
        --from-file=config.alloy="${CONFIG_FILE}" \
        --dry-run=client -o yaml | kubectl apply -f -
fi

echo -e "${GREEN}✓ ConfigMap updated${NC}"
echo ""

# echo -e "${GREEN}Step 2: Restarting Grafana Alloy StatefulSet...${NC}"

# # Restart StatefulSetu pro načtení nové konfigurace
# kubectl rollout restart statefulset/${STATEFULSET_NAME} -n ${NAMESPACE}

# echo -e "${GREEN}✓ Rollout restart initiated${NC}"
# echo ""

# echo -e "${GREEN}Step 3: Waiting for rollout to complete...${NC}"

# # Čekání na dokončení rollout
# kubectl rollout status statefulset/${STATEFULSET_NAME} -n ${NAMESPACE} --timeout=120s

# echo ""
# echo -e "${GREEN}✓ Alloy config successfully updated on production!${NC}"
# echo ""

# Zobrazení stavu podů
echo -e "${YELLOW}Current pod status:${NC}"
kubectl get pods -l app.kubernetes.io/name=grafana-alloy

echo ""
echo -e "${YELLOW}To check logs:${NC}"
echo "  kubectl logs -f statefulset/${STATEFULSET_NAME}"
echo ""
echo -e "${YELLOW}To port-forward for live debugging:${NC}"
echo "  kubectl port-forward -n ${NAMESPACE} service/grafana-alloy 12345:12345"
