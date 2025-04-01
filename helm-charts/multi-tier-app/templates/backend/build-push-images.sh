#!/bin/bash
# Script to build and push backend Docker images to ECR

# Set colors for better readability
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to check if a command was successful
check_status() {
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Success: $1${NC}"
  else
    echo -e "${RED}❌ Failed: $1${NC}"
    exit 1
  fi
}

# Set variables
REGION=eu-west-1
ECR_REPO_NAME=backend

# Get AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
check_status "Get AWS account ID"

# Create ECR repository if it doesn't exist
aws ecr describe-repositories --repository-names $ECR_REPO_NAME --region $REGION > /dev/null 2>&1 || \
  aws ecr create-repository --repository-name $ECR_REPO_NAME --region $REGION
check_status "Create/verify ECR repository"

# Log in to ECR
echo -e "${YELLOW}Logging in to ECR...${NC}"
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com
check_status "Login to ECR"

# Navigate to backend directory
cd "$(dirname "$0")"

# Build and push the main backend image
echo -e "${YELLOW}Building and pushing main backend image...${NC}"
docker build -t $AWS_ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO_NAME:latest .
check_status "Build backend image"

docker push $AWS_ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO_NAME:latest
check_status "Push backend image"

# Build and push the canary backend image
echo -e "${YELLOW}Building and pushing canary backend image...${NC}"
docker build -t $AWS_ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO_NAME:canary -f Dockerfile.canary .
check_status "Build canary backend image"

docker push $AWS_ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO_NAME:canary
check_status "Push canary backend image"

echo -e "${GREEN}=== Images successfully built and pushed to ECR ===${NC}"
echo -e "Main image: $AWS_ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO_NAME:latest"
echo -e "Canary image: $AWS_ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO_NAME:canary"

# Update the deployment template placeholders with actual AWS account ID
sed -i "s/\${AWS_ACCOUNT_ID}/$AWS_ACCOUNT_ID/g" ../temp/backend-deployment.yaml
sed -i "s/\${AWS_ACCOUNT_ID}/$AWS_ACCOUNT_ID/g" ../temp/backend-canary-deployment.yaml