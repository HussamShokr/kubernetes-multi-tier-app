#!/bin/bash
# Script to deploy the multi-tier application on AWS EKS

# Set colors for better readability
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== Multi-Tier Application Deployment on AWS EKS ===${NC}"
echo -e "${YELLOW}==========================================${NC}"

# Function to display the progress
progress_step() {
  echo -e "\n${YELLOW}Step $1: $2${NC}"
}

# Function to check if a command was successful
check_status() {
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Success: $1${NC}"
  else
    echo -e "${RED}❌ Failed: $1${NC}"
    exit 1
  fi
}

# Step 0: Create EKS cluster if it doesn't exist
progress_step "0" "Creating EKS cluster (if it doesn't exist)"
if ! eksctl get cluster --name multi-tier-cluster 2>/dev/null; then
  echo "Creating new EKS cluster. This will take 15-20 minutes..."
  eksctl create cluster -f cluster-setup/eks-cluster.yaml
  check_status "EKS cluster creation"
else
  echo "EKS cluster already exists."
fi

# Update kubeconfig
aws eks update-kubeconfig --name multi-tier-cluster --region us-east-1
check_status "Updating kubeconfig"

# Step 1: Create EBS Storage Class
progress_step "1" "Creating EBS Storage Class"
kubectl apply -f cluster-setup/aws-storage-class.yaml
check_status "EBS Storage Class creation"

# Step 2: Create namespaces
progress_step "2" "Creating namespaces"
kubectl create namespace multi-tier 2>/dev/null || true
kubectl create namespace monitoring 2>/dev/null || true
check_status "Namespace creation"

# Step 3: Apply RBAC configuration
progress_step "3" "Applying RBAC configuration"
kubectl apply -f cluster-setup/rbac-config.yaml
check_status "RBAC configuration"

# Step 4: Deploy the multi-tier application with Helm
progress_step "4" "Deploying multi-tier application with Helm"
helm install multi-tier-app ./helm-charts/multi-tier-app
check_status "Helm chart installation"

# Wait for deployments to be ready
echo "Waiting for deployments to be ready..."
kubectl rollout status deployment/frontend -n multi-tier --timeout=180s
kubectl rollout status deployment/backend -n multi-tier --timeout=180s
check_status "Application deployments"

# Step 5: Apply MongoDB StatefulSet
progress_step "5" "Setting up stateful application management"
# Create MongoDB secrets and ConfigMap
kubectl apply -f stateful/mongodb-secret.yaml
kubectl apply -f stateful/mongodb-init-configmap.yaml
check_status "MongoDB secrets and ConfigMap"

# Deploy MongoDB StatefulSet and service
kubectl apply -f stateful/mongodb-statefulset.yaml
kubectl apply -f stateful/mongodb-service.yaml
check_status "MongoDB deployment"

# Wait for MongoDB to be ready
echo "Waiting for MongoDB to be ready..."
kubectl wait --for=condition=Ready pod/mongodb-0 -n multi-tier --timeout=300s
check_status "MongoDB ready state"

# Configure backup system
kubectl apply -f stateful/backup-pvc.yaml
kubectl apply -f stateful/mongodb-backup-cronjob.yaml
check_status "Backup system configuration"

# Step 6: Configure networking and security
progress_step "6" "Setting up networking and security"
kubectl apply -f networking/network-policies.yaml
check_status "Network policies"

kubectl apply -f networking/pod-security.yaml
check_status "Pod security configuration"

# Step 7: Setup the AWS Load Balancer Controller
progress_step "7" "Setting up AWS Load Balancer Controller"
echo "Creating IAM policy for the AWS Load Balancer Controller..."
curl -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam-policy.json 2>/dev/null || true

echo "Creating service account for the AWS Load Balancer Controller..."
eksctl create iamserviceaccount \
  --cluster=multi-tier-cluster \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/AWSLoadBalancerControllerIAMPolicy \
  --override-existing-serviceaccounts \
  --approve 2>/dev/null || true

echo "Installing AWS Load Balancer Controller using Helm..."
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=multi-tier-cluster \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
check_status "AWS Load Balancer Controller setup"

# Step 8: Deploy Ingress (after ALB Controller is ready)
progress_step "8" "Creating Ingress"
kubectl apply -f networking/ingress.yaml
check_status "Ingress setup"

# Step 9: Deploy monitoring and logging
progress_step "9" "Setting up monitoring and logging"
# Add Helm repos
echo "Adding Helm repositories..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add elastic https://helm.elastic.co
helm repo update
check_status "Helm repositories"

# Install Prometheus stack
echo "Installing Prometheus and Grafana..."
helm install prometheus prometheus-community/kube-prometheus-stack \
  -f monitoring/prometheus-values.yaml \
  --namespace monitoring
check_status "Prometheus and Grafana installation"

# Apply custom alert rules
kubectl apply -f monitoring/prometheus-rules.yaml
check_status "Prometheus alert rules"

# Configure service monitors
kubectl apply -f monitoring/service-monitors.yaml
check_status "Service monitors"

# Install EFK stack
echo "Installing EFK stack for logging..."
helm install efk elastic/elastic-stack -f monitoring/efk-values.yaml --namespace monitoring
check_status "EFK stack installation"

# Apply custom Fluentd configuration
kubectl apply -f monitoring/fluentd-configmap.yaml
check_status "Fluentd configuration"

# Step 10: Wait for resources to be available
progress_step "10" "Waiting for all resources to be available"
echo "Waiting for all pods to be ready (this may take several minutes)..."
sleep 60

# Step 11: Get access information
progress_step "11" "Getting access information"

echo -e "\n${YELLOW}Access Information:${NC}"

# Get ALB endpoints
echo "Checking for Ingress/ALB endpoints..."
sleep 30  # Give time for the ALB to be provisioned
INGRESS_ALB=$(kubectl get ingress multi-tier-ingress -n multi-tier -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
if [ -n "$INGRESS_ALB" ]; then
  echo -e "Application URL: ${GREEN}http://$INGRESS_ALB${NC}"
  echo -e "API URL: ${GREEN}http://$INGRESS_ALB/api${NC}"
else
  echo -e "${YELLOW}⚠️ Ingress ALB not yet available. It may take a few minutes to provision.${NC}"
  echo -e "Check later with: kubectl get ingress multi-tier-ingress -n multi-tier"
fi

# Get Prometheus URL
PROMETHEUS_URL=$(kubectl get svc prometheus-kube-prometheus-prometheus -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
if [ -n "$PROMETHEUS_URL" ]; then
  echo -e "Prometheus URL: ${GREEN}http://$PROMETHEUS_URL${NC}"
else
  echo -e "${YELLOW}⚠️ Prometheus LoadBalancer not yet available.${NC}"
  echo -e "Check later with: kubectl get svc prometheus-kube-prometheus-prometheus -n monitoring"
fi

# Get Grafana URL
GRAFANA_URL=$(kubectl get svc prometheus-grafana -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
if [ -n "$GRAFANA_URL" ]; then
  echo -e "Grafana URL: ${GREEN}http://$GRAFANA_URL${NC}"
  echo -e "Grafana credentials: ${GREEN}admin / admin123${NC}"
else
  echo -e "${YELLOW}⚠️ Grafana LoadBalancer not yet available.${NC}"
  echo -e "Check later with: kubectl get svc prometheus-grafana -n monitoring"
fi

# Get Kibana URL
KIBANA_URL=$(kubectl get svc efk-kibana -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
if [ -n "$KIBANA_URL" ]; then
  echo -e "Kibana URL: ${GREEN}http://$KIBANA_URL${NC}"
else
  echo -e "${YELLOW}⚠️ Kibana LoadBalancer not yet available.${NC}"
  echo -e "Check later with: kubectl get svc efk-kibana -n monitoring"
fi

echo -e "\n${GREEN}=== Deployment Complete! ===${NC}"
echo -e "Your application is now deployed on AWS EKS."
echo -e "${YELLOW}Note:${NC} Some AWS resources like Load Balancers may take a few minutes to be fully provisioned."
echo -e "You can check the status of your resources with:"
echo -e "  kubectl get all -n multi-tier"
echo -e "  kubectl get all -n monitoring"