#!/bin/bash
# Script to deploy the multi-tier application on AWS EKS with existence checks

# Set colors for better readability
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== Multi-Tier Application Deployment on AWS EKS with Existence Checks ===${NC}"
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

# Step 0: Verify EKS cluster exists
progress_step "0" "Verifying EKS cluster exists"
if ! eksctl get cluster --name multi-tier-cluster &>/dev/null; then
  echo "Creating new EKS cluster. This will take 15-20 minutes..."
  eksctl create cluster -f cluster-setup/eks-cluster.yaml
  check_status "EKS cluster creation"
else
  echo -e "${GREEN}EKS cluster already exists.${NC}"
fi

# Update kubeconfig
aws eks update-kubeconfig --name multi-tier-cluster --region eu-west-1
check_status "Updating kubeconfig"

# Step 1: Create Storage Class if it doesn't exist
progress_step "1" "Creating EBS Storage Class"
if ! resource_exists storageclass ebs-sc; then
  kubectl apply -f cluster-setup/aws-storage-class.yaml
  check_status "EBS Storage Class creation"
else
  echo -e "${GREEN}EBS Storage Class already exists.${NC}"
fi

# Step 2: Create namespaces if they don't exist
progress_step "2" "Creating namespaces"
# Check multi-tier namespace
if ! resource_exists namespace multi-tier; then
  kubectl create namespace multi-tier
  echo "namespace/multi-tier created"
else
  echo "namespace/multi-tier already exists"
fi

# Check monitoring namespace
if ! resource_exists namespace monitoring; then
  kubectl create namespace monitoring
  echo "namespace/monitoring created"
else
  echo "namespace/monitoring already exists"
fi
echo -e "${GREEN}✅ Success: Namespace creation${NC}"

# Step 3: Apply RBAC configuration
progress_step "3" "Applying RBAC configuration"
if ! resource_exists role pod-admin default; then
  kubectl apply -f cluster-setup/rbac-config.yaml
  check_status "RBAC configuration"
else
  echo -e "${GREEN}RBAC configuration already exists.${NC}"
fi

# Step 4: Deploy MongoDB components
progress_step "4" "Setting up MongoDB components"
# Check and apply MongoDB Secret
if ! resource_exists secret mongodb-secret multi-tier; then
  kubectl apply -f stateful/mongodb-secret.yaml
  echo "secret/mongodb-secret created"
else
  echo "secret/mongodb-secret already exists"
fi

# Check and apply MongoDB Init ConfigMap
if ! resource_exists configmap mongodb-init multi-tier; then
  kubectl apply -f stateful/mongodb-init-configmap.yaml
  echo "configmap/mongodb-init created"
else
  echo "configmap/mongodb-init already exists"
fi

# Check and apply MongoDB StatefulSet
if ! resource_exists statefulset mongodb multi-tier; then
  kubectl apply -f stateful/mongodb-statefulset.yaml
  echo "statefulset/mongodb created"
else
  echo "statefulset/mongodb already exists"
fi

# Check and apply MongoDB Service
if ! resource_exists service mongodb multi-tier; then
  kubectl apply -f stateful/mongodb-service.yaml
  echo "service/mongodb created"
else
  echo "service/mongodb already exists"
fi
echo -e "${GREEN}✅ Success: MongoDB setup${NC}"

# Step 5: Deploy Frontend components
progress_step "5" "Deploying Frontend components"
# Check and apply Frontend Deployment
if ! resource_exists deployment frontend multi-tier; then
  # We need to template the Helm files since they contain variables
  mkdir -p temp
  envsubst < helm-charts/multi-tier-app/templates/frontend/deployment.yaml | \
    sed 's/{{ .Values.frontend.name }}/frontend/g' | \
    sed 's/{{ .Values.global.namespace }}/multi-tier/g' | \
    sed 's/{{ .Values.frontend.replicaCount }}/2/g' | \
    sed 's/{{ .Values.frontend.image.repository }}/nginx/g' | \
    sed 's/{{ .Values.frontend.image.tag }}/1.21.0/g' | \
    sed 's/{{ .Values.frontend.image.pullPolicy }}/IfNotPresent/g' | \
    sed 's/{{ toYaml .Values.frontend.resources | indent 12 }}/          limits:\n            cpu: 500m\n            memory: 512Mi\n          requests:\n            cpu: 100m\n            memory: 128Mi/g' \
    > temp/frontend-deployment.yaml
  
  kubectl apply -f temp/frontend-deployment.yaml
  echo "deployment/frontend created"
else
  echo "deployment/frontend already exists"
fi

# Check and apply Frontend Service
if ! resource_exists service frontend multi-tier; then
  envsubst < helm-charts/multi-tier-app/templates/frontend/service.yaml | \
    sed 's/{{ .Values.frontend.name }}/frontend/g' | \
    sed 's/{{ .Values.global.namespace }}/multi-tier/g' | \
    sed 's/{{ .Values.frontend.service.type }}/ClusterIP/g' | \
    sed 's/{{ .Values.frontend.service.port }}/80/g' \
    > temp/frontend-service.yaml
  
  kubectl apply -f temp/frontend-service.yaml
  echo "service/frontend created"
else
  echo "service/frontend already exists"
fi

# Check and apply Frontend HPA
if ! resource_exists hpa frontend multi-tier; then
  envsubst < helm-charts/multi-tier-app/templates/frontend/hpa.yaml | \
    sed 's/{{- if .Values.frontend.autoscaling.enabled }}//' | \
    sed 's/{{- end }}//' | \
    sed 's/{{ .Values.frontend.name }}/frontend/g' | \
    sed 's/{{ .Values.global.namespace }}/multi-tier/g' | \
    sed 's/{{ .Values.frontend.autoscaling.minReplicas }}/2/g' | \
    sed 's/{{ .Values.frontend.autoscaling.maxReplicas }}/10/g' | \
    sed 's/{{ .Values.frontend.autoscaling.targetCPUUtilizationPercentage }}/80/g' \
    > temp/frontend-hpa.yaml
  
  kubectl apply -f temp/frontend-hpa.yaml
  echo "horizontalpodautoscaler.autoscaling/frontend created"
else
  echo "horizontalpodautoscaler.autoscaling/frontend already exists"
fi
echo -e "${GREEN}✅ Success: Frontend deployment${NC}"

# Step 6: Deploy Backend components
progress_step "6" "Deploying Backend components"
# Similar checks and processing for backend components
# ...

# Step 7: Configure networking and security
progress_step "7" "Setting up networking and security"
# Check and apply Network Policies
if ! resource_exists networkpolicy frontend-policy multi-tier; then
  kubectl apply -f networking/network-policies.yaml
  echo "networkpolicy.networking.k8s.io/frontend-policy created"
else
  echo "networkpolicy.networking.k8s.io/frontend-policy already exists"
fi

# Step 8: Setup AWS Load Balancer Controller
progress_step "8" "Setting up AWS Load Balancer Controller"
# Check if service account exists
if ! resource_exists serviceaccount aws-load-balancer-controller kube-system; then
  # Create IAM policy if it doesn't exist
  POLICY_EXISTS=$(aws iam list-policies --query "Policies[?PolicyName=='AWSLoadBalancerControllerIAMPolicy'].Arn" --output text)
  if [ -z "$POLICY_EXISTS" ]; then
    echo "Creating IAM policy for ALB Controller..."
    curl -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
    aws iam create-policy \
        --policy-name AWSLoadBalancerControllerIAMPolicy \
        --policy-document file://iam-policy.json
  else
    echo "IAM policy already exists"
  fi

  echo "Creating service account for ALB Controller..."
  eksctl create iamserviceaccount \
    --cluster=multi-tier-cluster \
    --namespace=kube-system \
    --name=aws-load-balancer-controller \
    --attach-policy-arn=arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/AWSLoadBalancerControllerIAMPolicy \
    --override-existing-serviceaccounts \
    --approve
fi

# Check if ALB controller is deployed
if ! kubectl get deployment -n kube-system aws-load-balancer-controller &>/dev/null; then
  echo "Installing AWS Load Balancer Controller..."
  helm repo add eks https://aws.github.io/eks-charts
  helm repo update

  helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName=multi-tier-cluster \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller
  check_status "AWS Load Balancer Controller installation"
else
  echo -e "${GREEN}AWS Load Balancer Controller already installed.${NC}"
fi

# Step 9: Apply Ingress resource
progress_step "9" "Creating Ingress resource"
if ! resource_exists ingress multi-tier-ingress multi-tier; then
  kubectl apply -f networking/ingress.yaml
  check_status "Ingress resource creation"
else
  echo -e "${GREEN}Ingress resource already exists.${NC}"
fi

# Step 10: Deploy monitoring and logging
progress_step "10" "Setting up monitoring and logging"
# Add Helm repos
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo add elastic https://helm.elastic.co 2>/dev/null || true
helm repo update

# Check if Prometheus is installed
if ! helm list -n monitoring | grep prometheus &>/dev/null; then
  echo "Installing Prometheus stack..."
  helm install prometheus prometheus-community/kube-prometheus-stack \
    -f monitoring/prometheus-values.yaml \
    --namespace monitoring
  check_status "Prometheus and Grafana installation"
else
  echo -e "${GREEN}Prometheus stack already installed.${NC}"
fi

# Check if alert rules exist
if ! resource_exists configmap prometheus-alert-rules monitoring; then
  kubectl apply -f monitoring/prometheus-rules.yaml
  check_status "Prometheus alert rules"
else
  echo -e "${GREEN}Prometheus alert rules already exist.${NC}"
fi

# Check if service monitors exist
if ! resource_exists servicemonitor frontend-monitor monitoring; then
  kubectl apply -f monitoring/service-monitors.yaml
  check_status "Service monitors"
else
  echo -e "${GREEN}Service monitors already exist.${NC}"
fi

# Check if EFK stack is installed
if ! helm list -n monitoring | grep efk &>/dev/null; then
  echo "Installing EFK stack for logging..."
  helm install efk elastic/elastic-stack -f monitoring/efk-values.yaml --namespace monitoring
  check_status "EFK stack installation"
else
  echo -e "${GREEN}EFK stack already installed.${NC}"
fi

# Check if Fluentd ConfigMap exists
if ! resource_exists configmap fluentd-config monitoring; then
  kubectl apply -f monitoring/fluentd-configmap.yaml
  check_status "Fluentd configuration"
else
  echo -e "${GREEN}Fluentd configuration already exists.${NC}"
fi

# Step 11: Configure backup system
progress_step "11" "Setting up backup system"
if ! resource_exists pvc mongodb-backup-pvc multi-tier; then
  kubectl apply -f stateful/backup-pvc.yaml
  check_status "Backup PVC creation"
else
  echo -e "${GREEN}Backup PVC already exists.${NC}"
fi

if ! resource_exists cronjob mongodb-backup multi-tier; then
  kubectl apply -f stateful/mongodb-backup-cronjob.yaml
  check_status "Backup CronJob creation"
else
  echo -e "${GREEN}Backup CronJob already exists.${NC}"
fi

# Clean up temporary files
rm -rf temp

# Get access information
progress_step "12" "Getting access information"
echo -e "\n${YELLOW}Access Information:${NC}"

# Get ALB endpoints
echo "Checking for Ingress/ALB endpoints..."
sleep 5  # Give time for the ALB to be provisioned
INGRESS_ALB=$(kubectl get ingress multi-tier-ingress -n multi-tier -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
if [ -n "$INGRESS_ALB" ]; then
  echo -e "Application URL: ${GREEN}http://$INGRESS_ALB${NC}"
  echo -e "API URL: ${GREEN}http://$INGRESS_ALB/api${NC}"
else
  echo -e "${YELLOW}⚠️ Ingress ALB not yet available. It may take a few minutes to provision.${NC}"
  echo -e "Check later with: kubectl get ingress multi-tier-ingress -n multi-tier"
fi

# Get monitoring URLs
PROMETHEUS_URL=$(kubectl get svc prometheus-kube-prometheus-prometheus -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
GRAFANA_URL=$(kubectl get svc prometheus-grafana -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
KIBANA_URL=$(kubectl get svc efk-kibana -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)

[ -n "$PROMETHEUS_URL" ] && echo -e "Prometheus URL: ${GREEN}http://$PROMETHEUS_URL${NC}" || echo -e "${YELLOW}⚠️ Prometheus LoadBalancer not yet available.${NC}"
[ -n "$GRAFANA_URL" ] && echo -e "Grafana URL: ${GREEN}http://$GRAFANA_URL${NC}\nGrafana credentials: ${GREEN}admin / admin123${NC}" || echo -e "${YELLOW}⚠️ Grafana LoadBalancer not yet available.${NC}"
[ -n "$KIBANA_URL" ] && echo -e "Kibana URL: ${GREEN}http://$KIBANA_URL${NC}" || echo -e "${YELLOW}⚠️ Kibana LoadBalancer not yet available.${NC}"

echo -e "\n${GREEN}=== Deployment Complete! ===${NC}"
echo -e "Your application has been deployed on AWS EKS with existence checks."
echo -e "${YELLOW}Note:${NC} Some AWS resources like Load Balancers may take a few minutes to be fully provisioned."