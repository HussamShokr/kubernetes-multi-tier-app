#!/bin/bash
# Script to create a self-signed SSL certificate for the ALB ingress

# Set colors for better readability
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== Creating self-signed SSL certificate for ALB ingress ===${NC}"

# Create a private key
openssl genrsa -out tls.key 2048
check_status "Generate private key"

# Create CSR configuration file
cat > csr.conf << EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn

[dn]
C = US
ST = State
L = Location
O = Organization
OU = OrganizationUnit
CN = multi-tier-app.local
EOF

# Create the CSR (Certificate Signing Request)
openssl req -new -key tls.key -out tls.csr -config csr.conf
check_status "Generate CSR"

# Create certificate configuration
cat > cert.conf << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = multi-tier-app.local
DNS.2 = *.multi-tier-app.local
EOF

# Create the self-signed certificate
openssl x509 -req -in tls.csr -signkey tls.key -out tls.crt -days 365 -extfile cert.conf
check_status "Generate self-signed certificate"

# Create Kubernetes TLS secret
kubectl create secret tls multi-tier-tls -n multi-tier --cert=tls.crt --key=tls.key
check_status "Create Kubernetes TLS secret"

# Request the certificate ARN from AWS ACM
echo -e "${YELLOW}Importing certificate to AWS ACM...${NC}"
CERT_ARN=$(aws acm import-certificate \
  --certificate fileb://tls.crt \
  --private-key fileb://tls.key \
  --region eu-west-1 \
  --output text)
check_status "Import certificate to ACM"

echo -e "${GREEN}Certificate imported successfully!${NC}"
echo -e "Certificate ARN: $CERT_ARN"
echo
echo -e "${YELLOW}Update your ingress annotations with:${NC}"
echo "alb.ingress.kubernetes.io/certificate-arn: $CERT_ARN"

# Clean up files
rm -f tls.key tls.csr tls.crt csr.conf cert.conf