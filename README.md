# Multi-Tier Kubernetes Application on AWS EKS

This repository contains Kubernetes manifests and deployment scripts for a production-ready multi-tier application deployed on AWS EKS (Elastic Kubernetes Service). The application follows cloud-native best practices with scalability, security, monitoring, and resilience built-in.

## Architecture

The deployment consists of a three-tier application:

1. **Frontend**: Nginx-based web server
2. **Backend**: Node.js API service with canary deployment capability
3. **Database**: MongoDB with persistent storage using AWS EBS volumes

The system also includes:
- Production-grade monitoring with Prometheus and Grafana
- Centralized logging with EFK stack (Elasticsearch, Fluentd, Kibana)
- Auto-scaling with Horizontal Pod Autoscalers
- Network security with Network Policies
- Automated backups with CronJobs
- Ingress with AWS Application Load Balancer

## Repository Structure

```
kubernetes-multi-tier-app/
├── cluster-setup/              # EKS cluster configuration files
│   ├── eks-cluster.yaml       # EKS cluster definition
│   ├── aws-storage-class.yaml # AWS EBS storage class
│   └── rbac-config.yaml       # RBAC configuration
├── helm-charts/                # Helm chart for the multi-tier application
│   └── multi-tier-app/        
│       ├── Chart.yaml         # Chart metadata
│       ├── values.yaml        # Default chart values
│       └── templates/         # Template files for Kubernetes resources
├── networking/                 # Networking and security configurations
│   ├── ingress.yaml           # AWS ALB Ingress
│   ├── network-policies.yaml  # Network security policies
│   └── pod-security.yaml      # Pod security standards
├── stateful/                   # StatefulSet and data persistence files
│   ├── mongodb-statefulset.yaml   # MongoDB StatefulSet
│   ├── mongodb-service.yaml       # MongoDB service
│   ├── mongodb-secret.yaml        # MongoDB secrets
│   ├── mongodb-init-configmap.yaml # MongoDB init script
│   ├── backup-pvc.yaml            # PVC for backups
│   ├── mongodb-backup-cronjob.yaml # Backup CronJob
│   └── mongodb-restore-job.yaml    # Restore Job
├── monitoring/                 # Monitoring and logging configurations
│   ├── prometheus-values.yaml  # Prometheus config
│   ├── efk-values.yaml        # EFK stack config
│   ├── prometheus-rules.yaml  # Alert rules
│   ├── service-monitors.yaml  # Service monitors
│   └── fluentd-configmap.yaml # Fluentd configuration
├── eks-deploy.sh              # Deployment script
├── eks-cleanup.sh             # Cleanup script
└── README.md                  # This file
```

## Prerequisites

- AWS Account with appropriate permissions
- AWS CLI configured with appropriate credentials
- `eksctl` installed (for EKS cluster creation)
- `kubectl` installed (for Kubernetes management)
- `helm` installed (for Helm chart deployment)

## Deployment Guide

### Step 1: Clone the Repository

```bash
git clone https://github.com/HussamShokr/kubernetes-multi-tier-app.git
cd kubernetes-multi-tier-app
```

### Step 2: Deploy the Application

The repository includes a comprehensive deployment script that handles:
- EKS cluster creation (if it doesn't exist)
- Storage class configuration
- Application deployment with Helm
- Database setup
- Security configurations
- AWS Load Balancer Controller setup
- Monitoring and logging deployment

To deploy everything:

```bash
chmod +x eks-deploy.sh
./eks-deploy.sh
```

The deployment will take approximately 20-30 minutes (with most of that time spent on EKS cluster creation).

### Step 3: Access the Application

After deployment, the script will display URLs for:
- The application frontend
- The API backend
- Prometheus monitoring
- Grafana dashboards
- Kibana for log exploration

The AWS Application Load Balancer may take a few minutes to become fully available.

## Cleanup

To remove all resources deployed by this repository:

```bash
chmod +x eks-cleanup.sh
./eks-cleanup.sh
```

The script will ask for confirmation and whether you want to delete the EKS cluster as well.

## Production Considerations

For production deployments, consider the following modifications:

1. **Security**:
   - Set stronger passwords in the MongoDB secrets
   - Implement AWS KMS for secret encryption
   - Enable HTTPS with a valid TLS certificate in ACM
   - Enable AWS WAF for the ALB

2. **High Availability**:
   - Deploy to multiple Availability Zones
   - Configure MongoDB replica sets
   - Consider using EFS for shared storage needs

3. **Disaster Recovery**:
   - Configure backup retention policies
   - Set up regular testing of restore procedures
   - Implement cross-region backup strategies

4. **Cost Optimization**:
   - Review instance types and adjust as needed
   - Configure cluster-autoscaler
   - Implement node spot instances for non-critical workloads

## Monitoring and Alerts

The deployment includes:
- CPU and memory usage dashboards
- Application performance metrics
- Automated alerts for resource constraints
- Log aggregation for troubleshooting

Access Grafana with the credentials provided at the end of the deployment script to explore metrics and dashboards.

## License

MIT License - see [LICENSE](LICENSE) file for details.
