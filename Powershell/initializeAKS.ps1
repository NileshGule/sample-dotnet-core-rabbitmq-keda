Param(
    [parameter(Mandatory = $false)]
    [string]$subscriptionName = "Microsoft Azure Sponsorship",
    [parameter(Mandatory = $false)]
    [string]$resourceGroupName = "kedaResourceGroup",
    [parameter(Mandatory = $false)]
    [string]$resourceGroupLocaltion = "South East Asia",
    [parameter(Mandatory = $false)]
    [string]$clusterName = "aksCluster",
    [parameter(Mandatory = $false)]
    [int16]$workerNodeCount = 1,
    [parameter(Mandatory = $false)]
    [string]$kubernetesVersion = "1.11.2"

)

# Set Azure subscription name
Write-Host "Setting Azure subscription to $subscriptionName"  -ForegroundColor Yellow
az account set --subscription=$subscriptionName

# Create resource group name
Write-Host "Creating resource group $resourceGroupName in region $resourceGroupLocaltion" -ForegroundColor Yellow
az group create `
    --name=$resourceGroupName `
    --location=$resourceGroupLocaltion `
    --output=jsonc

Write-Host "Creating Virtual Network"
az network vnet create `
    --resource-group $resourceGroupName `
    --name kedaVnet `
    --address-prefixes 10.0.0.0/8 `
    --subnet-name kedaAKSSubnet `
    --subnet-prefix 10.240.0.0/16 `
    --output=jsonc

# Create subnet for Virtual Node
Write-Host "Creating subnet for Virtual Node"
az network vnet subnet create `
    --resource-group $resourceGroupName `
    --vnet-name kedaVnet `
    --name kedaVirtualNodeSubnet `
    --address-prefixes 10.241.0.0/16 `
    --output=jsonc

# Create Service Principal
$password = $(az ad sp create-for-rbac `
        --name kedasp `
        --skip-assignment `
        --query password `
        --output tsv)

# Assign permissions to Virtual Network
$appId = $(az ad sp list --display-name kedasp --query [].appId -o tsv)

Write-Host "Password = $password"

# Get Virtual network Resource Id
$vNetId = $(az network vnet show --resource-group $resourceGroupName --name kedaVnet --query id -o tsv)

# Create Role assignment
az role assignment create `
    --assignee $appId `
    --scope $vNetId `
    --role Contributor `
    --output=jsonc

# Get AKS Subnet ID
$aksSubnetID = $(az network vnet subnet show --resource-group $resourceGroupName --vnet-name kedaVnet --name kedaAKSSubnet --query id -o tsv)

# Create AKS cluster
Write-Host "Creating AKS cluster $clusterName with resource group $resourceGroupName in region $resourceGroupLocaltion" -ForegroundColor Yellow
az aks create `
    --resource-group=$resourceGroupName `
    --name=$clusterName `
    --node-count=$workerNodeCount `
    --network-plugin azure `
    --service-cidr 10.0.0.0/16 `
    --dns-service-ip 10.0.0.10 `
    --docker-bridge-address 172.17.0.1/16 `
    --vnet-subnet-id $aksSubnetID `
    --service-principal $appId `
    --client-secret $password `
    --output=jsonc
# --kubernetes-version=$kubernetesVersion `

# Enable virtual node add on
az aks enable-addons `
    --resource-group $resourceGroupName `
    --name $clusterName `
    --addons virtual-node `
    --subnet-name kedaVirtualNodeSubnet `
    --output=jsonc

# Get credentials for newly created cluster
Write-Host "Getting credentials for cluster $clusterName" -ForegroundColor Yellow
az aks get-credentials `
    --resource-group=$resourceGroupName `
    --name=$clusterName `
    --output=jsonc

Write-Host "Successfully created cluster $clusterName with kubernetes version $kubernetesVersion and $workerNodeCount node(s)" -ForegroundColor Green

Write-Host "Creating cluster role binding for Kubernetes dashboard" -ForegroundColor Green

kubectl create clusterrolebinding kubernetes-dashboard `
    -n kube-system `
    --clusterrole=cluster-admin `
    --serviceaccount=kube-system:kubernetes-dashboard

Write-Host "Creating Tiller service account for Helm" -ForegroundColor Green

# source common variables
. .\var.ps1

Set-Location $helmRootDirectory

kubectl apply -f .\helm-rbac.yaml

Write-Host "Initializing Helm with Tiller service account" -ForegroundColor Green

helm init --service-account tiller

helm repo add kedacore https://kedacore.azureedge.net/helm

helm repo update

Write-Host "Initializing KEDA on AKS cluster $clusterName" -ForegroundColor Green

helm install kedacore/keda-edge `
    --devel `
    --set logLevel=debug `
    --namespace keda `
    --name keda

Set-Location ~/projects/sample-dotnet-core-rabbitmq-keda/Powershell