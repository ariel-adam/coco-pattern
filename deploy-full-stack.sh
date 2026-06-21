#!/bin/bash
# deploy-full-stack.sh
#
# Full post-cluster-creation automation:
#   1. Deploys the CoCo validated pattern (helm template)
#   2. Waits for ArgoCD and apps
#   3. Creates KataConfig
#   4. Loads Vault secrets
#   5. Fixes ExternalSecrets
#   6. Creates peer-pods-cm + peer-pods-secret (Azure)
#   7. Creates osc-feature-gates ConfigMap
#   8. Installs Sandbox CRD for OpenShell
#   9. Deploys OpenShell workloads
#  10. Deploys console plugins (osc, coco, trustee)
#
# Usage: bash deploy-full-stack.sh
#
# Prerequisites: oc logged in, azure.env loaded, Docker running

set -e
export PATH="$HOME/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Load credentials ──────────────────────────────────────────────────────────
_COCO_AZURE_ENV="${COCO_AZURE_ENV:-$HOME/.config/coco-pattern/azure.env}"
[ -f "$_COCO_AZURE_ENV" ] && source "$_COCO_AZURE_ENV"

# ── Step 1: Deploy CoCo pattern ───────────────────────────────────────────────
info "Step 1: Deploying CoCo validated pattern..."
cd "$SCRIPT_DIR"

helm template \
  --include-crds \
  --name-template "coco-pattern" \
  "oci://quay.io/hybridcloudpatterns/pattern-install" \
  -f values-global.yaml \
  --set "main.git.repoURL=https://github.com/ariel-adam/coco-pattern" \
  --set "main.git.revision=main" \
  2>&1 | grep -v "^Pulled\|^Digest" | oc apply -f- 2>&1 | grep -v "unchanged\|^$" || true

# Wait for CRD then apply again
sleep 30
helm template \
  --include-crds \
  --name-template "coco-pattern" \
  "oci://quay.io/hybridcloudpatterns/pattern-install" \
  -f values-global.yaml \
  --set "main.git.repoURL=https://github.com/ariel-adam/coco-pattern" \
  --set "main.git.revision=main" \
  2>&1 | grep -v "^Pulled\|^Digest" | oc apply -f- 2>&1 | grep -v "unchanged\|^$"

# ── Step 2: Wait for patterns operator + ArgoCD ───────────────────────────────
info "Step 2: Waiting for patterns operator and ArgoCD (~10 min)..."
for i in $(seq 1 20); do
  OPERATOR=$(oc get pods -n openshift-operators --no-headers 2>/dev/null | \
    grep "patterns-operator-controller" | grep "2/2\|1/1" | wc -l | tr -d ' ')
  APPS=$(oc get application.argoproj.io -n coco-pattern-simple --no-headers 2>/dev/null | wc -l | tr -d ' ')
  echo "  [$(date +%H:%M:%S)] patterns-operator: $OPERATOR | ArgoCD apps: $APPS"
  [ "$APPS" -ge 7 ] && info "ArgoCD apps deployed!" && break
  sleep 30
done

# ── Step 3: Create KataConfig ─────────────────────────────────────────────────
info "Step 3: Creating KataConfig (kata node install ~25 min)..."
cat << 'EOF' | oc apply -f -
apiVersion: kataconfiguration.openshift.io/v1
kind: KataConfig
metadata:
  name: default-kata-config
spec:
  enablePeerPods: true
EOF

# ── Step 4: Load Vault secrets ────────────────────────────────────────────────
info "Step 4: Waiting for Vault, then loading secrets..."
for i in $(seq 1 30); do
  VAULT=$(oc get pods -n vault --no-headers 2>/dev/null | grep "vault-0.*Running" | wc -l | tr -d ' ')
  [ "$VAULT" -ge 1 ] && break
  sleep 20
done
make load-secrets 2>&1 | tail -3

# ── Step 5: Force ExternalSecrets sync ───────────────────────────────────────
info "Step 5: Waiting for Trustee operator, then syncing ExternalSecrets..."
for i in $(seq 1 15); do
  TRUSTEE=$(oc get pods -n trustee-operator-system --no-headers 2>/dev/null | \
    grep "controller-manager.*Running" | wc -l | tr -d ' ')
  [ "$TRUSTEE" -ge 1 ] && break
  sleep 30
done
sleep 30
oc annotate externalsecret -A --all force-sync="$(date +%s)" --overwrite 2>&1 | tail -2

# ── Step 6: Create peer-pods resources ────────────────────────────────────────
info "Step 6: Creating peer-pods-cm and peer-pods-secret..."

SUBSCRIPTION="1a84145c-974c-4237-9046-64a34c09752f"
ARO_RG=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.azure.resourceGroupName}' 2>/dev/null)
CLUSTER_SUFFIX=$(echo "$ARO_RG" | sed 's/aro-//')
NSG_ID="/subscriptions/$SUBSCRIPTION/resourceGroups/$ARO_RG/providers/Microsoft.Network/networkSecurityGroups/coco-aro-cluster-${CLUSTER_SUFFIX}-nsg"
SUBNET_ID="/subscriptions/$SUBSCRIPTION/resourceGroups/coco-aro-rg/providers/Microsoft.Network/virtualNetworks/coco-vnet/subnets/worker-subnet"

cat << EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: peer-pods-cm
  namespace: openshift-sandboxed-containers-operator
data:
  CLOUD_PROVIDER: "azure"
  VXLAN_PORT: "9000"
  AZURE_IMAGE_ID: ""
  AZURE_INSTANCE_SIZE: "Standard_DC4as_v5"
  AZURE_INSTANCE_SIZES: "Standard_DC2as_v5,Standard_DC4as_v5,Standard_DC8as_v5,Standard_DC16as_v5,Standard_D4as_v5"
  AZURE_RESOURCE_GROUP: "coco-aro-rg"
  AZURE_REGION: "eastus"
  AZURE_SUBNET_ID: "$SUBNET_ID"
  AZURE_NSG_ID: "$NSG_ID"
  DISABLECVM: "false"
  PROXY_TIMEOUT: "30m"
EOF

oc create secret generic peer-pods-secret \
  --from-literal=AZURE_CLIENT_ID="${AZURE_CLIENT_ID}" \
  --from-literal=AZURE_CLIENT_SECRET="${AZURE_CLIENT_SECRET}" \
  --from-literal=AZURE_TENANT_ID="${AZURE_TENANT_ID}" \
  --from-literal=AZURE_SUBSCRIPTION_ID="${SUBSCRIPTION}" \
  -n openshift-sandboxed-containers-operator 2>&1 | grep -v "already exists" || true

# ── Step 7: Create osc-feature-gates ──────────────────────────────────────────
info "Step 7: Creating osc-feature-gates ConfigMap..."
cat << 'EOF' | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: osc-feature-gates
  namespace: openshift-sandboxed-containers-operator
data:
  SANDBOXED_CONTAINERS_EXTENSION: "true"
  PEER_PODS: "true"
EOF

# ── Step 8: Wait for pod VM image creation ────────────────────────────────────
info "Step 8: Waiting for pod VM image creation job (~15 min)..."
for i in $(seq 1 25); do
  sleep 60
  RC=$(oc get runtimeclass kata-remote 2>/dev/null | grep -c "kata-remote" || echo 0)
  KATA=$(oc get kataconfig default-kata-config \
    -o jsonpath='{.status.kataNodes.readyNodeCount}/{.status.kataNodes.nodeCount}' 2>/dev/null)
  echo "  [$(date +%H:%M:%S)] Kata nodes: $KATA | kata-remote RuntimeClass: $RC"
  [ "$RC" -ge 1 ] && info "kata-remote ready!" && break
done

# Fix DISABLECVM if pod VM image was built as TrustedLaunchSupported
GALLERY=$(az sig list -g coco-aro-rg --query "[0].name" -o tsv 2>/dev/null)
if [ -n "$GALLERY" ]; then
  SEC_TYPE=$(az sig image-definition show -g coco-aro-rg \
    --gallery-name "$GALLERY" \
    --gallery-image-definition podvm-image \
    --query "features[?name=='SecurityType'].value | [0]" -o tsv 2>/dev/null)
  info "Pod VM image SecurityType: $SEC_TYPE"
  if [ "$SEC_TYPE" = "TrustedLaunchSupported" ]; then
    warn "Image is TrustedLaunchSupported — switching to Standard_D4as_v5 with DISABLECVM=true"
    oc patch cm peer-pods-cm -n openshift-sandboxed-containers-operator \
      --type merge -p '{"data":{"AZURE_INSTANCE_SIZE":"Standard_D4as_v5","DISABLECVM":"true"}}' 2>&1
    oc rollout restart daemonset/osc-caa-ds \
      -n openshift-sandboxed-containers-operator 2>&1
    oc rollout status daemonset/osc-caa-ds \
      -n openshift-sandboxed-containers-operator --timeout=90s 2>&1 | tail -1
  fi
fi

# ── Step 9: Fix RBAC for OpenShell gateway ────────────────────────────────────
info "Step 9: Fixing OpenShell gateway RBAC and creating Sandbox CRD..."
cat << 'EOF' | oc apply -f -
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: sandboxes.agents.x-k8s.io
spec:
  group: agents.x-k8s.io
  names:
    kind: Sandbox
    listKind: SandboxList
    plural: sandboxes
    singular: sandbox
  scope: Namespaced
  versions:
  - name: v1alpha1
    served: true
    storage: true
    subresources:
      status: {}
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            x-kubernetes-preserve-unknown-fields: true
          status:
            type: object
            x-kubernetes-preserve-unknown-fields: true
EOF

# Wait for openshell to be installed (from deploy-openshell.sh)
sleep 10
oc patch role openshell-sandbox -n openshell --type=json -p='[
  {"op":"replace","path":"/rules/2/verbs","value":["create","delete","get","list","patch","update","watch"]}
]' 2>&1 | grep -v "^$" || warn "openshell-sandbox role not ready yet (deploy-openshell.sh will handle)"

# ── Step 10: Deploy OpenShell ─────────────────────────────────────────────────
info "Step 10: Deploying OpenShell workloads..."
bash "$SCRIPT_DIR/deploy-openshell.sh" 2>&1 | tail -10

# ── Step 11: Force sync hello-openshift and kbs-access ───────────────────────
info "Step 11: Syncing CoCo demo workloads..."
oc patch application.argoproj.io hello-openshift kbs-access \
  -n coco-pattern-simple \
  --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}' 2>&1 | head -2

# ── Step 12: Deploy console plugins ──────────────────────────────────────────
info "Step 12: Deploying console plugins..."

NEW_REGISTRY="default-route-openshift-image-registry.apps.$(oc whoami --show-server 2>/dev/null | \
  python3 -c 'import sys; h=sys.stdin.read().split("//")[1].split(":")[0]; print(h.replace("api.","apps.").rstrip("/"))')"

TOKEN=$(oc whoami -t)

# Expose registry
oc patch configs.imageregistry.operator.openshift.io cluster \
  --type merge -p '{"spec":{"defaultRoute":true}}' 2>&1
sleep 10
REGISTRY=$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}' 2>/dev/null)
info "Registry: $REGISTRY"

# Create plugin namespaces
for plugin in osc coco trustee; do
  oc new-project "${plugin}-openshift-console-plugin" 2>&1 | tail -1 || true
done

# Login to registry
docker login "$REGISTRY" -u kubeadmin -p "$TOKEN" 2>&1 | tail -1

# Retag images for new cluster registry
REGISTRY_EXT="default-route-openshift-image-registry.apps.m7v5n14w.eastus.aroapp.io"
docker tag "$REGISTRY_EXT/osc-openshift-console-plugin/osc-openshift-console-plugin:v420-patched" \
  "$REGISTRY/osc-openshift-console-plugin/osc-openshift-console-plugin:latest" 2>/dev/null || true
docker tag "$REGISTRY_EXT/coco-openshift-console-plugin/coco-openshift-console-plugin:v420-peerpod" \
  "$REGISTRY/coco-openshift-console-plugin/coco-openshift-console-plugin:latest" 2>/dev/null || true
docker tag "$REGISTRY_EXT/trustee-openshift-console-plugin/trustee-openshift-console-plugin:v420-r17" \
  "$REGISTRY/trustee-openshift-console-plugin/trustee-openshift-console-plugin:latest" 2>/dev/null || true

# Push via pod port-forward
REG_POD=$(oc get pods -n openshift-image-registry --no-headers 2>/dev/null | \
  grep "^image-registry" | awk '{print $1}' | head -1)

oc port-forward pod/$REG_POD -n openshift-image-registry 28000:5000 2>/dev/null &
PF_PID=$!
sleep 5

for plugin in osc coco trustee; do
  NS="${plugin}-openshift-console-plugin"
  info "  Pushing $plugin..."
  skopeo copy \
    --format v2s2 \
    --dest-creds "kubeadmin:${TOKEN}" \
    --dest-tls-verify=false \
    docker-daemon:"$REGISTRY/$NS/${plugin}-openshift-console-plugin:latest" \
    docker://localhost:28000/$NS/${plugin}-openshift-console-plugin:latest 2>&1 | tail -2
done

kill $PF_PID 2>/dev/null || true

INTERNAL_REG="image-registry.openshift-image-registry.svc:5000"
for plugin in osc coco trustee; do
  NS="${plugin}-openshift-console-plugin"
  CHART="/tmp/${plugin}-openshift-console-plugin/charts/openshift-console-plugin"
  DIGEST=$(oc get istag "${plugin}-openshift-console-plugin:latest" \
    -n "$NS" -o jsonpath='{.image.metadata.name}' 2>&1)
  helm upgrade -i "${plugin}-openshift-console-plugin" "$CHART" \
    -n "$NS" \
    --set "plugin.name=${plugin}-openshift-console-plugin" \
    --set "plugin.image=$INTERNAL_REG/$NS/${plugin}-openshift-console-plugin@$DIGEST" \
    --set "plugin.imagePullPolicy=Always" \
    2>&1 | tail -2
done

# ── Step 13: Create TrusteeConfig CRD stub (plugin needs it for nav gating) ──
info "Step 13: Ensuring TrusteeConfig CRD for console plugin..."
oc get crd trusteeconfigs.confidentialcontainers.org 2>/dev/null || \
cat << 'EOF' | oc apply -f -
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: trusteeconfigs.confidentialcontainers.org
spec:
  group: confidentialcontainers.org
  names:
    kind: TrusteeConfig
    listKind: TrusteeConfigList
    plural: trusteeconfigs
    singular: trusteeconfig
  scope: Namespaced
  versions:
  - name: v1alpha1
    served: true
    storage: true
    subresources:
      status: {}
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            x-kubernetes-preserve-unknown-fields: true
          status:
            type: object
            x-kubernetes-preserve-unknown-fields: true
EOF

# Restart console
oc rollout restart deployment/console -n openshift-console 2>&1 | tail -1
oc rollout status deployment/console -n openshift-console --timeout=60s 2>&1 | tail -1

# ── Final summary ─────────────────────────────────────────────────────────────
echo ""
info "=== Deployment Complete ==="
echo ""
echo "  Console: https://console-openshift-console.$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null)"
echo "  Username: kubeadmin"
PASS=$(az aro list-credentials -n coco-aro-cluster -g coco-aro-rg -o json 2>/dev/null | \
  python3 -c "import json,sys; print(json.load(sys.stdin).get('kubeadminPassword',''))" 2>/dev/null)
echo "  Password: $PASS"
echo ""
echo "  Pods:"
oc get pods -n openshell --no-headers 2>&1 | awk '{print "    " $1, $3}'
echo ""
oc get application.argoproj.io -n coco-pattern-simple 2>&1 | \
  awk 'NR>1 {printf "  %-30s %-12s %s\n", $1, $2, $3}'
