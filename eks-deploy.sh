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

# Step 0.1: Create IAM access entry for EKS cluster
progress_step "0.1" "Creating IAM access entry for EKS cluster"

# Get current IAM user ARN
CURRENT_USER_ARN=$(aws sts get-caller-identity --query "Arn" --output text)
echo "Creating access entry for current IAM user: $CURRENT_USER_ARN"

# Create access entry for the user with admin privileges
eksctl create accessentry \
  --cluster multi-tier-cluster \
  --region eu-west-1 \
  --principal-arn $CURRENT_USER_ARN \
  --access-policy arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --type STANDARD 2>/dev/null || echo "Access entry may already exist"
check_status "IAM access entry creation"

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
# Create temp directory if it doesn't exist
mkdir -p temp

# Check and apply Frontend Deployment
if ! resource_exists deployment frontend multi-tier; then
  # Create frontend deployment file directly
  cat > temp/frontend-deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: multi-tier
  labels:
    app: frontend
    tier: frontend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: frontend
      tier: frontend
  template:
    metadata:
      labels:
        app: frontend
        tier: frontend
    spec:
      containers:
      - name: frontend
        image: nginx:1.21.0
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 80
        resources:
          limits:
            cpu: 500m
            memory: 512Mi
          requests:
            cpu: 100m
            memory: 128Mi
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 10
EOF
  
  kubectl apply -f temp/frontend-deployment.yaml
  echo "deployment/frontend created"
else
  echo "deployment/frontend already exists"
fi

# Check and apply Frontend Service
if ! resource_exists service frontend multi-tier; then
  cat > temp/frontend-service.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: frontend
  namespace: multi-tier
  labels:
    app: frontend
    tier: frontend
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 80
    protocol: TCP
    name: http
  selector:
    app: frontend
    tier: frontend
EOF
  
  kubectl apply -f temp/frontend-service.yaml
  echo "service/frontend created"
else
  echo "service/frontend already exists"
fi

# Check and apply Frontend HPA
if ! resource_exists hpa frontend multi-tier; then
  cat > temp/frontend-hpa.yaml << 'EOF'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: frontend
  namespace: multi-tier
  labels:
    app: frontend
    tier: frontend
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: frontend
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 80
EOF
  
  kubectl apply -f temp/frontend-hpa.yaml
  echo "horizontalpodautoscaler.autoscaling/frontend created"
else
  echo "horizontalpodautoscaler.autoscaling/frontend already exists"
fi
echo -e "${GREEN}✅ Success: Frontend deployment${NC}"

# Step 6: Deploy Backend components
progress_step "6" "Deploying Backend components"
# Check and apply Backend Deployment
if ! resource_exists deployment backend multi-tier; then
  cat > temp/backend-deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: multi-tier
  labels:
    app: backend
    tier: backend
    version: stable
spec:
  replicas: 2
  selector:
    matchLabels:
      app: backend
      tier: backend
  template:
    metadata:
      labels:
        app: backend
        tier: backend
        version: stable
    spec:
      containers:
      - name: backend
        image: node:16-alpine
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 3000
        env:
        - name: MONGO_URI
          value: "mongodb://app-user:app-password@mongodb.multi-tier.svc.cluster.local:27017/app-database"
        resources:
          limits:
            cpu: 1000m
            memory: 1Gi
          requests:
            cpu: 200m
            memory: 256Mi
EOF

  kubectl apply -f temp/backend-deployment.yaml
  echo "deployment/backend created"
else
  echo "deployment/backend already exists"
fi

# Check and apply Backend Service
if ! resource_exists service backend multi-tier; then
  cat > temp/backend-service.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: multi-tier
  labels:
    app: backend
    tier: backend
spec:
  type: ClusterIP
  ports:
  - port: 3000
    targetPort: 3000
    protocol: TCP
    name: http
  selector:
    app: backend
    tier: backend
EOF
  
  kubectl apply -f temp/backend-service.yaml
  echo "service/backend created"
else
  echo "service/backend already exists"
fi

# Check and apply Backend HPA
if ! resource_exists hpa backend multi-tier; then
  cat > temp/backend-hpa.yaml << 'EOF'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: backend
  namespace: multi-tier
  labels:
    app: backend
    tier: backend
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: backend
  minReplicas: 2
  maxReplicas: 8
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
EOF
  
  kubectl apply -f temp/backend-hpa.yaml
  echo "horizontalpodautoscaler.autoscaling/backend created"
else
  echo "horizontalpodautoscaler.autoscaling/backend already exists"
fi

# Check and apply Backend Canary Deployment
if ! resource_exists deployment backend-canary multi-tier; then
  cat > temp/backend-canary-deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-canary
  namespace: multi-tier
  labels:
    app: backend
    tier: backend
    version: canary
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backend
      tier: backend
      version: canary
  template:
    metadata:
      labels:
        app: backend
        tier: backend
        version: canary
    spec:
      containers:
      - name: backend-canary
        image: node:16-alpine-canary
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 3000
        env:
        - name: MONGO_URI
          value: "mongodb://app-user:app-password@mongodb.multi-tier.svc.cluster.local:27017/app-database"
        resources:
          limits:
            cpu: 1000m
            memory: 1Gi
          requests:
            cpu: 200m
            memory: 256Mi
EOF
  
  kubectl apply -f temp/backend-canary-deployment.yaml
  echo "deployment/backend-canary created"
else
  echo "deployment/backend-canary already exists"
fi
echo -e "${GREEN}✅ Success: Backend deployment${NC}"

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

# IMPORTANT: First associate OIDC provider with the cluster
echo "Associating OIDC provider with the cluster..."
eksctl utils associate-iam-oidc-provider \
  --region=eu-west-1 \
  --cluster=multi-tier-cluster \
  --approve 2>/dev/null || echo "OIDC provider may already be associated"
check_status "OIDC provider association"

# Create IAM Policy for ALB Controller
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

# Create IAM Service Account
echo "Creating service account for ALB Controller..."
eksctl create iamserviceaccount \
  --cluster=multi-tier-cluster \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=$(aws iam list-policies --query "Policies[?PolicyName=='AWSLoadBalancerControllerIAMPolicy'].Arn" --output text) \
  --override-existing-serviceaccounts \
  --approve

# Wait for service account to propagate
echo "Waiting for service account to propagate..."
sleep 10

# Check if ALB controller is already deployed
if ! kubectl get deployment -n kube-system aws-load-balancer-controller &>/dev/null; then
  echo "Installing AWS Load Balancer Controller..."
  helm repo add eks https://aws.github.io/eks-charts
  helm repo update

  helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName=multi-tier-cluster \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller
  
  # Wait for controller to be ready
  echo "Waiting for AWS Load Balancer Controller to be ready..."
  kubectl wait --for=condition=available --timeout=120s deployment/aws-load-balancer-controller -n kube-system
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

# Install Elasticsearch
if ! helm list -n monitoring | grep elasticsearch &>/dev/null; then
  echo "Installing Elasticsearch..."
  helm install elasticsearch elastic/elasticsearch \
    --namespace monitoring \
    --set replicas=1 \
    --set minimumMasterNodes=1 \
    --set resources.requests.cpu=250m \
    --set resources.requests.memory=512Mi \
    --set resources.limits.cpu=1000m \
    --set resources.limits.memory=2Gi \
    --set persistence.enabled=true \
    --set persistence.size=10Gi
  check_status "Elasticsearch installation"
else
  echo -e "${GREEN}Elasticsearch already installed.${NC}"
fi

# Install Kibana
if ! helm list -n monitoring | grep kibana &>/dev/null; then
  echo "Installing Kibana..."
  helm install kibana elastic/kibana \
    --namespace monitoring \
    --set service.type=LoadBalancer
  check_status "Kibana installation"
else
  echo -e "${GREEN}Kibana already installed.${NC}"
fi

# Install Fluentd using Kubernetes manifests
if ! resource_exists daemonset fluentd monitoring; then
  echo "Installing Fluentd..."
  kubectl apply -f monitoring/fluentd-configmap.yaml
  
  # Create a Fluentd DaemonSet
  cat > temp/fluentd-daemonset.yaml << 'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluentd
  namespace: monitoring
  labels:
    app: fluentd
spec:
  selector:
    matchLabels:
      app: fluentd
  template:
    metadata:
      labels:
        app: fluentd
    spec:
      serviceAccount: fluentd
      serviceAccountName: fluentd
      tolerations:
      - key: node-role.kubernetes.io/master
        effect: NoSchedule
      containers:
      - name: fluentd
        image: fluent/fluentd-kubernetes-daemonset:v1.14-debian-elasticsearch7-1
        env:
          - name: FLUENT_ELASTICSEARCH_HOST
            value: "elasticsearch-master"
          - name: FLUENT_ELASTICSEARCH_PORT
            value: "9200"
          - name: FLUENTD_SYSTEMD_CONF
            value: disable
        resources:
          limits:
            memory: 500Mi
          requests:
            cpu: 100m
            memory: 200Mi
        volumeMounts:
        - name: varlog
          mountPath: /var/log
        - name: varlibdockercontainers
          mountPath: /var/lib/docker/containers
          readOnly: true
        - name: config-volume
          mountPath: /fluentd/etc/conf.d
      terminationGracePeriodSeconds: 30
      volumes:
      - name: varlog
        hostPath:
          path: /var/log
      - name: varlibdockercontainers
        hostPath:
          path: /var/lib/docker/containers
      - name: config-volume
        configMap:
          name: fluentd-config
EOF

  # Create service account for Fluentd
  cat > temp/fluentd-rbac.yaml << 'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: fluentd
  namespace: monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: fluentd
rules:
- apiGroups:
  - ""
  resources:
  - pods
  - namespaces
  verbs:
  - get
  - list
  - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: fluentd
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: fluentd
subjects:
- kind: ServiceAccount
  name: fluentd
  namespace: monitoring
EOF

  kubectl apply -f temp/fluentd-rbac.yaml
  kubectl apply -f temp/fluentd-daemonset.yaml
  check_status "Fluentd installation"
else
  echo -e "${GREEN}Fluentd already installed.${NC}"
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
KIBANA_URL=$(kubectl get svc kibana-kibana -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)

[ -n "$PROMETHEUS_URL" ] && echo -e "Prometheus URL: ${GREEN}http://$PROMETHEUS_URL${NC}" || echo -e "${YELLOW}⚠️ Prometheus LoadBalancer not yet available.${NC}"
[ -n "$GRAFANA_URL" ] && echo -e "Grafana URL: ${GREEN}http://$GRAFANA_URL${NC}\nGrafana credentials: ${GREEN}admin / admin123${NC}" || echo -e "${YELLOW}⚠️ Grafana LoadBalancer not yet available.${NC}"
[ -n "$KIBANA_URL" ] && echo -e "Kibana URL: ${GREEN}http://$KIBANA_URL${NC}" || echo -e "${YELLOW}⚠️ Kibana LoadBalancer not yet available.${NC}"

echo -e "\n${GREEN}=== Deployment Complete! ===${NC}"
echo -e "Your application has been deployed on AWS EKS with existence checks."
echo -e "${YELLOW}Note:${NC} Some AWS resources like Load Balancers may take a few minutes to be fully provisioned."