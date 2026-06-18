#!/bin/bash

# ARO CoCo Pattern Deployment Script
# This script sets up an ARO cluster optimized for Confidential Containers

set -e

# Optional: ~/.config/coco-pattern/azure.env (chmod 600) — AZURE_* / ARO_* for SP-based ARO create
_COCO_AZURE_ENV="${COCO_AZURE_ENV:-$HOME/.config/coco-pattern/azure.env}"
if [ -f "$_COCO_AZURE_ENV" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$_COCO_AZURE_ENV"
    set +a
fi

echo "🚀 ARO CoCo Pattern Setup Script"
echo "================================="
echo

# Configuration variables
RESOURCE_GROUP="${ARO_RESOURCE_GROUP:-coco-aro-rg}"
CLUSTER_NAME="${ARO_CLUSTER_NAME:-coco-aro-cluster}"
LOCATION="${ARO_LOCATION:-eastus}"
VNET_NAME="${ARO_VNET_NAME:-coco-vnet}"
MASTER_SUBNET="${ARO_MASTER_SUBNET:-master-subnet}"
WORKER_SUBNET="${ARO_WORKER_SUBNET:-worker-subnet}"
# Standard_D4s_v5 is widely available; Standard_DC* (confidential) may not be in all regions
MASTER_VM_SIZE="${ARO_MASTER_VM_SIZE:-Standard_D8s_v5}"
WORKER_VM_SIZE="${ARO_WORKER_VM_SIZE:-Standard_D4s_v5}"
WORKER_COUNT="${ARO_WORKER_COUNT:-3}"
ARO_VERSION="${ARO_VERSION:-}"  # e.g. "4.20.15" — leave empty for ARO default
PULL_SECRET_FILE="${PULL_SECRET_FILE:-$HOME/pull-secret.json}"
# Optional: pre-created service principal (avoids needing Azure AD app creation rights)
ARO_CLIENT_ID="${ARO_CLIENT_ID:-}"
ARO_CLIENT_SECRET="${ARO_CLIENT_SECRET:-}"

echo "📋 Configuration:"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  Cluster Name: $CLUSTER_NAME"
echo "  Location: $LOCATION"
echo "  Master VM Size: $MASTER_VM_SIZE"
echo "  Worker VM Size: $WORKER_VM_SIZE"
echo "  Worker Count: $WORKER_COUNT"
if [ -n "$ARO_CLIENT_ID" ]; then
    echo "  Cluster SP: $ARO_CLIENT_ID (pre-created, no AAD app create needed)"
fi
echo

# Check prerequisites
echo "1. Checking prerequisites..."
commands=("az")
for cmd in "${commands[@]}"; do
    if ! command -v $cmd &> /dev/null; then
        echo "❌ $cmd is not installed. Please install Azure CLI first."
        exit 1
    else
        echo "✅ $cmd found"
    fi
done

# Check Azure login
if ! az account show &> /dev/null; then
    echo "❌ Not logged into Azure. Please run: az login"
    exit 1
else
    echo "✅ Azure CLI authenticated"
    SUBSCRIPTION=$(az account show --query name -o tsv)
    echo "   Subscription: $SUBSCRIPTION"
fi

# Check pull secret
if [ ! -f "$PULL_SECRET_FILE" ]; then
    echo "❌ Pull secret not found at: $PULL_SECRET_FILE"
    echo "   Download from https://console.redhat.com/openshift/install/pull-secret"
    exit 1
else
    echo "✅ Pull secret found"
fi

echo

# Register providers
echo "2. Registering Azure providers..."
az provider register --namespace Microsoft.RedHatOpenShift --wait
az provider register --namespace Microsoft.Compute --wait
az provider register --namespace Microsoft.Storage --wait
az provider register --namespace Microsoft.Authorization --wait
echo "✅ Providers registered"

# Check ARO CLI (built-in in Azure CLI 2.67+)
echo "3. Checking ARO CLI..."
if az aro --help &> /dev/null; then
    echo "✅ az aro available (Azure CLI built-in)"
else
    echo "Installing ARO extension..."
    if az extension show --name aro &> /dev/null; then
        echo "✅ ARO extension already installed"
    else
        az extension add -n aro 2>/dev/null || az extension add -n aro --index https://az.aroapp.io/stable
        echo "✅ ARO extension installed"
    fi
fi

echo

# Create resource group
echo "4. Creating resource group..."
if az group show --name "$RESOURCE_GROUP" &> /dev/null; then
    echo "✅ Resource group '$RESOURCE_GROUP' already exists"
else
    az group create --name "$RESOURCE_GROUP" --location "$LOCATION"
    echo "✅ Resource group '$RESOURCE_GROUP' created"
fi

# If using pre-created SP, assign it Contributor on the resource group
if [ -n "$ARO_CLIENT_ID" ]; then
    echo "4b. Assigning cluster SP Contributor on resource group..."
    SUB_ID=$(az account show -o tsv --query id)
    RG_SCOPE="/subscriptions/$SUB_ID/resourceGroups/$RESOURCE_GROUP"
    if az role assignment list --assignee "$ARO_CLIENT_ID" --scope "$RG_SCOPE" --query "[].roleDefinitionName" -o tsv 2>/dev/null | grep -q "Contributor"; then
        echo "✅ SP already has Contributor on $RESOURCE_GROUP"
    else
        az role assignment create --assignee "$ARO_CLIENT_ID" --role Contributor --scope "$RG_SCOPE"
        echo "✅ SP assigned Contributor on $RESOURCE_GROUP"
    fi
fi

# Create virtual network
echo "5. Creating virtual network..."
if az network vnet show --resource-group "$RESOURCE_GROUP" --name "$VNET_NAME" &> /dev/null; then
    echo "✅ Virtual network '$VNET_NAME' already exists"
else
    az network vnet create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VNET_NAME" \
        --address-prefixes 10.0.0.0/16
    echo "✅ Virtual network '$VNET_NAME' created"
fi

# Create master subnet
echo "6. Creating master subnet..."
if az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "$MASTER_SUBNET" &> /dev/null; then
    echo "✅ Master subnet '$MASTER_SUBNET' already exists"
else
    az network vnet subnet create \
        --resource-group "$RESOURCE_GROUP" \
        --vnet-name "$VNET_NAME" \
        --name "$MASTER_SUBNET" \
        --address-prefixes 10.0.1.0/24 \
        --service-endpoints Microsoft.ContainerRegistry
    echo "✅ Master subnet '$MASTER_SUBNET' created"
fi

# Create worker subnet
echo "7. Creating worker subnet..."
if az network vnet subnet show --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" --name "$WORKER_SUBNET" &> /dev/null; then
    echo "✅ Worker subnet '$WORKER_SUBNET' already exists"
else
    az network vnet subnet create \
        --resource-group "$RESOURCE_GROUP" \
        --vnet-name "$VNET_NAME" \
        --name "$WORKER_SUBNET" \
        --address-prefixes 10.0.2.0/24 \
        --service-endpoints Microsoft.ContainerRegistry
    echo "✅ Worker subnet '$WORKER_SUBNET' created"
fi

echo

# VM size note (DC series = confidential computing, may not be available in all regions)
echo "8. Worker VM size: $WORKER_VM_SIZE"
if [[ "$WORKER_VM_SIZE" == Standard_DC* ]]; then
    echo "   (Confidential computing SKU - ensure it's available in your region)"
fi

# Create ARO cluster
echo "9. Creating ARO cluster..."
echo "⚠️  This will take 30-45 minutes..."
echo "   Cluster: $CLUSTER_NAME"
echo "   Worker VMs: $WORKER_COUNT x $WORKER_VM_SIZE"
echo
if [ -z "$ARO_CLIENT_ID" ] || [ -z "$ARO_CLIENT_SECRET" ]; then
    echo "ℹ️  AAD / Graph: If \`az aro create\` fails with \"Insufficient privileges\" or Graph errors,"
    echo "   create an app registration + secret (cluster service principal), grant it Contributor on this"
    echo "   resource group, then re-run with ARO_CLIENT_ID and ARO_CLIENT_SECRET set (see script header)."
    echo
fi

read -p "Continue with ARO cluster creation? (y/N) " -n 1 -r
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "🚀 Creating ARO cluster..."
    
    ARO_OPTS=(
        --resource-group "$RESOURCE_GROUP"
        --name "$CLUSTER_NAME"
        --vnet "$VNET_NAME"
        --master-subnet "$MASTER_SUBNET"
        --worker-subnet "$WORKER_SUBNET"
        --master-vm-size "$MASTER_VM_SIZE"
        --worker-vm-size "$WORKER_VM_SIZE"
        --worker-count "$WORKER_COUNT"
        --pull-secret "@$PULL_SECRET_FILE"
        --location "$LOCATION"
    )
    if [ -n "$ARO_CLIENT_ID" ] && [ -n "$ARO_CLIENT_SECRET" ]; then
        ARO_OPTS+=(--client-id "$ARO_CLIENT_ID" --client-secret "$ARO_CLIENT_SECRET")
    fi
    if [ -n "$ARO_VERSION" ]; then
        ARO_OPTS+=(--version "$ARO_VERSION")
        echo "   OCP Version: $ARO_VERSION"
    fi
    
    az aro create "${ARO_OPTS[@]}"
    
    echo "✅ ARO cluster created successfully!"
    
    # Get cluster details
    echo
    echo "10. Getting cluster credentials..."
    
    CONSOLE_URL=$(az aro show --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --query "consoleProfile.url" -o tsv)
    API_SERVER=$(az aro show --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --query "apiserverProfile.url" -o tsv)
    CREDENTIALS=$(az aro list-credentials --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP")
    USERNAME=$(echo "$CREDENTIALS" | jq -r '.kubeadminUsername')
    PASSWORD=$(echo "$CREDENTIALS" | jq -r '.kubeadminPassword')
    
    echo "✅ Cluster credentials retrieved"
    echo
    echo "🎉 ARO CLUSTER READY FOR COCO DEPLOYMENT!"
    echo "=========================================="
    echo
    echo "📊 Cluster Information:"
    echo "  Console URL: $CONSOLE_URL"
    echo "  API Server: $API_SERVER"
    echo "  Username: $USERNAME"
    echo "  Password: $PASSWORD"
    echo
    echo "🔐 Login Commands:"
    echo "  oc login $API_SERVER -u $USERNAME -p '$PASSWORD'"
    echo "  # Or login via web console: $CONSOLE_URL"
    echo
    echo "🚀 Next Steps - Deploy CoCo Pattern:"
    echo "  1. Login to the cluster:"
    echo "     oc login $API_SERVER -u $USERNAME -p '$PASSWORD'"
    echo "  2. Generate secrets:"
    echo "     bash scripts/gen-secrets.sh"
    echo "  3. Deploy the pattern:"
    echo "     ./pattern.sh make install"
    echo
    echo "📊 Monitor deployment:"
    echo "     oc get applications -A"
    echo "     oc get pods -n hello-openshift"
    echo
    echo "🌐 Test applications (after deployment):"
    echo "     oc get routes -n hello-openshift"
    echo "     # Apps will be available at *.apps.$CLUSTER_NAME.aroapp.io"
    
else
    echo "ARO cluster creation cancelled."
    exit 1
fi
