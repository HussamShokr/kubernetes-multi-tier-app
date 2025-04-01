#!/bin/bash
# Script to clean up all deployed resources on AWS EKS

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

# Ask for confirmation
read -p "This will remove all resources deployed by the multi-tier application on AWS EKS. Are you sure? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo -e "${RED}Cleanup aborted.${NC}"
  exit 1
fi

# Step 1: Remove Ingress resources
progress_step "1" "Removing Ingress resources"
echo "This will trigger deletion of AWS ALB..."
kubectl delete ingress -n multi-tier multi-tier-ingress 2>/dev/null || true
check_status "Ingress removal"
# Wait for ALB to be deleted
echo "Waiting for AWS ALB to be deleted..."
sleep 30

# Step 2: Remove the application namespace
progress_step "2" "Removing application namespace"
echo "This will delete all resources in the multi-tier namespace..."
kubectl delete namespace multi-tier 2>/dev/null || true
check_status "Application namespace removal"

# Step 3: Remove monitoring namespace
progress_step "3" "Removing monitoring namespace"
echo "This will delete all monitoring resources including Prometheus, Grafana, and EFK stack..."
kubectl delete namespace monitoring 2>/dev/null || true
check_status "Monitoring namespace removal"

# Step 4: Remove helm releases
progress_step "4" "Removing Helm releases"
echo "Removing Helm releases..."
helm uninstall multi-tier-app 2>/dev/null || true
helm uninstall prometheus -n monitoring 2>/dev/null || true
helm uninstall efk -n monitoring 2>/dev/null || true
check_status "Helm releases removal"

# Step 5: Clean up AWS Load Balancer Controller
progress_step "5" "Cleaning up AWS Load Balancer Controller"
echo "Removing AWS Load Balancer Controller..."
helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true
check_status "AWS Load Balancer Controller removal"

# Step 6: Clean up IAM service account
progress_step "6" "Cleaning up IAM service account"
echo "Removing IAM service account..."
eksctl delete iamserviceaccount \
  --cluster=multi-tier-cluster \
  --namespace=kube-system \
  --name=aws-load-balancer-controller 2>/dev/null || true
check_status "IAM service account removal"

# Step 7: Clean up persistent volumes
progress_step "7" "Cleaning up persistent volumes"
echo "Removing any orphaned PVs..."
for pv in $(kubectl get pv -o name 2>/dev/null); do
  echo "Deleting $pv..."
  kubectl delete $pv --force --grace-period=0 2>/dev/null || true
done
check_status "PV cleanup"

# Step 8: Ask if user wants to delete the EKS cluster
progress_step "8" "EKS cluster cleanup"
echo -e "${YELLOW}Do you want to delete the EKS cluster as well? This will remove all compute nodes and the control plane.${NC}"
echo -e "${RED}WARNING: This is irreversible and will delete ALL resources in the cluster!${NC}"
read -p "Delete EKS cluster? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  echo -e "${YELLOW}Deleting EKS cluster 'multi-tier-cluster'... This may take 15-20 minutes.${NC}"
  eksctl delete cluster --name multi-tier-cluster --region eu-west-1
  check_status "EKS cluster deletion"
else
  echo -e "${YELLOW}Cluster deletion skipped. You can delete it later with:${NC}"
  echo -e "eksctl delete cluster --name multi-tier-cluster --region eu-west-1"
fi

# Step 9: Clean up IAM policy
progress_step "9" "Cleaning up IAM policy"
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