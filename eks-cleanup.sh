#!/bin/bash
# Script to clean up all deployed resources on AWS EKS with existence checks

# Set colors for better readability
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== Multi-Tier Application Cleanup Script for AWS EKS ===${NC}"
echo -e "${YELLOW}=======================================${NC}"

# Function to display the progress
progress_step() {
  echo -e "\n${YELLOW}Step $1: $2${NC}"
}

# Function to check if a command was successful
check_status() {
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ $1${NC}"
  else
    echo -e "${RED}✗ $1 (but continuing)${NC}"
  fi
}

# Function to check if a Kubernetes resource exists
resource_exists() {
  local resource_type=$1
  local resource_name=$2
  local namespace=$3
  
  if [ -z "$namespace" ]; then
    kubectl get $resource_type $resource_name &>/dev/null
  else
    kubectl get $resource_type $resource_name -n $namespace &>/dev/null
  fi
  
  return $?
}

# Ask for confirmation
read -p "This will remove all resources deployed by the multi-tier application on AWS EKS. Are you sure? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo -e "${RED}Cleanup aborted.${NC}"
  exit 1
fi

# Step 1: Remove Ingress resources
progress_step "1" "Removing Ingress resources"
if resource_exists ingress multi-tier-ingress multi-tier; then
  echo "Removing ingress multi-tier-ingress..."
  kubectl delete ingress multi-tier-ingress -n multi-tier
  echo "Waiting for AWS ALB to be deleted..."
  sleep 30
  check_status "Ingress removal"
else
  echo "Ingress resource not found, skipping."
fi

# Step 2: Remove application components from multi-tier namespace
progress_step "2" "Removing application components"
echo "Removing deployments, services, and HPAs..."

# Frontend components
if resource_exists deployment frontend multi-tier; then
  kubectl delete deployment frontend -n multi-tier
  echo "Deleted deployment/frontend"
fi

if resource_exists service frontend multi-tier; then
  kubectl delete service frontend -n multi-tier
  echo "Deleted service/frontend"
fi

if resource_exists hpa frontend multi-tier; then
  kubectl delete hpa frontend -n multi-tier
  echo "Deleted horizontalpodautoscaler/frontend"
fi

# Backend components
if resource_exists deployment backend multi-tier; then
  kubectl delete deployment backend -n multi-tier
  echo "Deleted deployment/backend"
fi

if resource_exists deployment backend-canary multi-tier; then
  kubectl delete deployment backend-canary -n multi-tier
  echo "Deleted deployment/backend-canary"
fi

if resource_exists service backend multi-tier; then
  kubectl delete service backend -n multi-tier
  echo "Deleted service/backend"
fi

if resource_exists hpa backend multi-tier; then
  kubectl delete hpa backend -n multi-tier
  echo "Deleted horizontalpodautoscaler/backend"
fi

# Step 3: Remove MongoDB resources
progress_step "3" "Removing MongoDB resources"

# CronJob and Backups
if resource_exists cronjob mongodb-backup multi-tier; then
  kubectl delete cronjob mongodb-backup -n multi-tier
  echo "Deleted cronjob/mongodb-backup"
fi

# Give time for any running jobs to complete their deletion
sleep 5

# StatefulSet and Service
if resource_exists statefulset mongodb multi-tier; then
  kubectl delete statefulset mongodb -n multi-tier --cascade=foreground
  echo "Deleted statefulset/mongodb"
fi

if resource_exists service mongodb multi-tier; then
  kubectl delete service mongodb -n multi-tier
  echo "Deleted service/mongodb"
fi

# ConfigMap and Secret
if resource_exists configmap mongodb-init multi-tier; then
  kubectl delete configmap mongodb-init -n multi-tier
  echo "Deleted configmap/mongodb-init"
fi

if resource_exists secret mongodb-secret multi-tier; then
  kubectl delete secret mongodb-secret -n multi-tier
  echo "Deleted secret/mongodb-secret"
fi

# Step 4: Remove PVCs and PVs
progress_step "4" "Removing PVCs and PVs"
echo "Removing PVCs..."
if resource_exists pvc mongodb-backup-pvc multi-tier; then
  kubectl delete pvc mongodb-backup-pvc -n multi-tier
  echo "Deleted persistentvolumeclaim/mongodb-backup-pvc"
fi

# Also check for data PVCs from StatefulSets
if resource_exists pvc data-mongodb-0 multi-tier; then
  kubectl delete pvc data-mongodb-0 -n multi-tier
  echo "Deleted persistentvolumeclaim/data-mongodb-0"
fi

# Wait for PVs to be released
echo "Waiting for PVs to be released..."
sleep 15

# Step 5: Remove Network Policies
progress_step "5" "Removing Network Policies"
for policy in frontend-policy backend-policy database-policy; do
  if resource_exists networkpolicy $policy multi-tier; then
    kubectl delete networkpolicy $policy -n multi-tier
    echo "Deleted networkpolicy/$policy"
  fi
done

# Step 6: Remove Monitoring Resources
progress_step "6" "Removing Monitoring Resources"
echo "Removing Prometheus, Grafana, and EFK stack..."

# Check if Prometheus Helm release exists
if helm list -n monitoring | grep prometheus &>/dev/null; then
  helm uninstall prometheus -n monitoring
  echo "Uninstalled Helm release: prometheus"
fi

# Check if EFK Helm release exists
if helm list -n monitoring | grep efk &>/dev/null; then
  helm uninstall efk -n monitoring
  echo "Uninstalled Helm release: efk"
fi

# Remove custom resources
if resource_exists configmap prometheus-alert-rules monitoring; then
  kubectl delete configmap prometheus-alert-rules -n monitoring
  echo "Deleted configmap/prometheus-alert-rules"
fi

for sm in frontend-monitor backend-monitor mongodb-monitor; do
  if resource_exists servicemonitor $sm monitoring; then
    kubectl delete servicemonitor $sm -n monitoring
    echo "Deleted servicemonitor/$sm"
  fi
done

if resource_exists configmap fluentd-config monitoring; then
  kubectl delete configmap fluentd-config -n monitoring
  echo "Deleted configmap/fluentd-config"
fi

# Step 7: Remove AWS Load Balancer Controller
progress_step "7" "Removing AWS Load Balancer Controller"
if kubectl get deployment -n kube-system aws-load-balancer-controller &>/dev/null; then
  echo "Uninstalling AWS Load Balancer Controller..."
  helm uninstall aws-load-balancer-controller -n kube-system
  check_status "AWS Load Balancer Controller removal"
fi

# Step 8: Remove IAM Service Account
progress_step "8" "Removing IAM Service Account"
if eksctl get iamserviceaccount --cluster=multi-tier-cluster --namespace=kube-system --name=aws-load-balancer-controller &>/dev/null; then
  echo "Removing IAM service account..."
  eksctl delete iamserviceaccount \
    --cluster=multi-tier-cluster \
    --namespace=kube-system \
    --name=aws-load-balancer-controller
  check_status "IAM service account removal"
fi

# Step 9: Remove Storage Class
progress_step "9" "Removing Storage Class"
if resource_exists storageclass ebs-sc; then
  echo "Removing EBS Storage Class..."
  kubectl delete storageclass ebs-sc
  check_status "Storage class removal"
fi

# Step 10: Remove Namespaces
progress_step "10" "Removing Namespaces"
for ns in multi-tier monitoring; do
  if resource_exists namespace $ns; then
    echo "Removing namespace $ns..."
    kubectl delete namespace $ns --wait=false
    echo "Namespace $ns deletion initiated (may take some time to complete)"
  fi
done

# Step 11: Remove IAM Access Entry
progress_step "11" "Removing IAM Access Entry"
CURRENT_USER_ARN=$(aws sts get-caller-identity --query "Arn" --output text)
echo "Removing access entry for IAM user: $CURRENT_USER_ARN"
eksctl delete accessentry \
  --cluster multi-tier-cluster \
  --region eu-west-1 \
  --principal-arn $CURRENT_USER_ARN \
  --type STANDARD 2>/dev/null || echo "Access entry may already be deleted"

# Step 12: Ask about cluster deletion
progress_step "12" "EKS cluster cleanup"
echo -e "${YELLOW}Do you want to delete the EKS cluster as well? This will remove all compute nodes and the control plane.${NC}"
echo -e "${RED}WARNING: This is irreversible and will delete ALL resources in the cluster!${NC}"
read -p "Delete EKS cluster 'multi-tier-cluster'? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  echo -e "${YELLOW}Deleting EKS cluster 'multi-tier-cluster'... This may take 15-20 minutes.${NC}"
  eksctl delete cluster --name multi-tier-cluster --region eu-west-1
  check_status "EKS cluster deletion"
else
  echo -e "${YELLOW}Cluster deletion skipped. You can delete it later with:${NC}"
  echo -e "eksctl delete cluster --name multi-tier-cluster --region eu-west-1"
fi

# Step 13: Clean up IAM policy (optional)
progress_step "13" "Cleaning up IAM policy"
echo "Do you want to remove the IAM policy for the AWS Load Balancer Controller?"
read -p "Remove IAM policy? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  echo "Looking up policy ARN..."
  POLICY_ARN=$(aws iam list-policies --query 'Policies[?PolicyName==`AWSLoadBalancerControllerIAMPolicy`].Arn' --output text)
  if [ -n "$POLICY_ARN" ]; then
    echo "Deleting IAM policy $POLICY_ARN..."
    aws iam delete-policy --policy-arn $POLICY_ARN
    check_status "IAM policy deletion"
  else
    echo "IAM policy not found."
  fi
else
  echo -e "${YELLOW}IAM policy deletion skipped.${NC}"
fi

echo -e "\n${GREEN}=== Cleanup Complete! ===${NC}"
echo -e "All deployed resources have been removed."
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo -e "${YELLOW}Note:${NC} The EKS cluster is still running. Remember to delete it when no longer needed to avoid incurring AWS charges."
fi