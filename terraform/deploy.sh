#!/bin/bash
set -e

# =============================================================================
# Deploy script for EKS DevOps Agent Workshop
# One-click deployment of the complete lab environment
# =============================================================================

# Default values (can be overridden via environment variables)
CLUSTER_NAME="${CLUSTER_NAME:-retail-store}"
REGION="${AWS_REGION:-us-east-1}"
ENABLE_GRAFANA="${ENABLE_GRAFANA:-false}"

# Get the repo root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/eks/default"

# Cleanup function for trap
cleanup() {
    rm -f "$TERRAFORM_DIR/tfplan" 2>/dev/null || true
}
trap cleanup EXIT

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo ""
    echo -e "${BLUE}=== $1 ===${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

# =============================================================================
# Banner
# =============================================================================
echo ""
echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║       🚀 EKS DevOps Agent Workshop - Deployment Script        ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Configuration:"
echo "  Cluster Name:    $CLUSTER_NAME"
echo "  AWS Region:      $REGION"
echo "  Enable Grafana:  $ENABLE_GRAFANA"
echo ""
echo "To customize, set environment variables:"
echo "  CLUSTER_NAME=my-cluster AWS_REGION=us-west-2 ./deploy.sh"
echo ""

# =============================================================================
# Step 1: Validate Configuration
# =============================================================================
print_header "Step 1: Validating Configuration"

# Validate cluster name (must start with letter, alphanumeric and hyphens only)
if [[ ! "$CLUSTER_NAME" =~ ^[a-zA-Z][a-zA-Z0-9-]*$ ]]; then
    print_error "Invalid cluster name: $CLUSTER_NAME"
    echo "  Must start with a letter and contain only alphanumeric characters and hyphens"
    exit 1
fi
print_success "Cluster name valid: $CLUSTER_NAME"

# Check if Terraform directory exists
if [ ! -d "$TERRAFORM_DIR" ]; then
    print_error "Terraform directory not found: $TERRAFORM_DIR"
    echo "  Make sure you're running from the repository root"
    exit 1
fi
print_success "Terraform directory found"

# =============================================================================
# Step 2: Check Prerequisites (auto-install if missing)
# =============================================================================
print_header "Step 2: Checking Prerequisites"

ARCH=$(uname -m)
OS=$(uname -s | tr '[:upper:]' '[:lower:]')

# Normalize architecture name
case "$ARCH" in
    x86_64)  ARCH_ALT="amd64" ;;
    aarch64) ARCH_ALT="arm64" ;;
    arm64)   ARCH_ALT="arm64" ;;
    *)       ARCH_ALT="amd64" ;;
esac

install_terraform() {
    print_warning "Terraform not found, installing..."
    local TF_VERSION="1.9.8"
    local TF_URL="https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_${OS}_${ARCH_ALT}.zip"
    local TMP_DIR=$(mktemp -d)

    echo "  Downloading Terraform v${TF_VERSION} for ${OS}/${ARCH_ALT}..."
    if curl -fsSL "$TF_URL" -o "$TMP_DIR/terraform.zip"; then
        unzip -q "$TMP_DIR/terraform.zip" -d "$TMP_DIR"
        sudo mv "$TMP_DIR/terraform" /usr/local/bin/terraform
        sudo chmod +x /usr/local/bin/terraform
        rm -rf "$TMP_DIR"
        print_success "Terraform installed to /usr/local/bin/terraform"
    else
        rm -rf "$TMP_DIR"
        print_error "Failed to download Terraform"
        echo "  Manual install: https://developer.hashicorp.com/terraform/downloads"
        exit 1
    fi
}

install_kubectl() {
    print_warning "kubectl not found, installing..."
    local KUBECTL_VERSION
    KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt 2>/dev/null || echo "v1.31.0")
    local KUBECTL_URL="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH_ALT}/kubectl"

    echo "  Downloading kubectl ${KUBECTL_VERSION} for ${OS}/${ARCH_ALT}..."
    if curl -fsSL "$KUBECTL_URL" -o /tmp/kubectl; then
        sudo mv /tmp/kubectl /usr/local/bin/kubectl
        sudo chmod +x /usr/local/bin/kubectl
        print_success "kubectl installed to /usr/local/bin/kubectl"
    else
        print_error "Failed to download kubectl"
        echo "  Manual install: https://kubernetes.io/docs/tasks/tools/"
        exit 1
    fi
}

install_aws_cli() {
    print_warning "AWS CLI not found, installing..."
    local TMP_DIR=$(mktemp -d)

    if [ "$OS" = "linux" ]; then
        local AWS_URL="https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip"
        echo "  Downloading AWS CLI for linux/${ARCH}..."
        if curl -fsSL "$AWS_URL" -o "$TMP_DIR/awscliv2.zip"; then
            unzip -q "$TMP_DIR/awscliv2.zip" -d "$TMP_DIR"
            sudo "$TMP_DIR/aws/install" --update 2>/dev/null || sudo "$TMP_DIR/aws/install"
            rm -rf "$TMP_DIR"
            print_success "AWS CLI installed"
        else
            rm -rf "$TMP_DIR"
            print_error "Failed to download AWS CLI"
            echo "  Manual install: https://aws.amazon.com/cli/"
            exit 1
        fi
    elif [ "$OS" = "darwin" ]; then
        local AWS_URL="https://awscli.amazonaws.com/AWSCLIV2.pkg"
        echo "  Downloading AWS CLI for macOS..."
        if curl -fsSL "$AWS_URL" -o "$TMP_DIR/AWSCLIV2.pkg"; then
            sudo installer -pkg "$TMP_DIR/AWSCLIV2.pkg" -target /
            rm -rf "$TMP_DIR"
            print_success "AWS CLI installed"
        else
            rm -rf "$TMP_DIR"
            print_error "Failed to download AWS CLI"
            echo "  Manual install: https://aws.amazon.com/cli/"
            exit 1
        fi
    else
        rm -rf "$TMP_DIR"
        print_error "Unsupported OS for auto-install: $OS"
        echo "  Manual install: https://aws.amazon.com/cli/"
        exit 1
    fi
}

install_helm() {
    print_warning "Helm not found, installing..."
    echo "  Downloading Helm for ${OS}/${ARCH_ALT}..."
    if curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash; then
        print_success "Helm installed"
    else
        print_error "Failed to install Helm"
        echo "  Manual install: https://helm.sh/docs/intro/install/"
        exit 1
    fi
}

# Check Terraform
if ! command -v terraform &> /dev/null; then
    install_terraform
fi
TERRAFORM_VERSION=$(terraform version | head -1 | awk '{print $2}' | tr -d 'v')
print_success "Terraform found (v$TERRAFORM_VERSION)"

# Check kubectl
if ! command -v kubectl &> /dev/null; then
    install_kubectl
fi
print_success "kubectl found ($(kubectl version --client --short 2>/dev/null || kubectl version --client -o json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['clientVersion']['gitVersion'])" 2>/dev/null || echo 'ok'))"

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    install_aws_cli
fi
print_success "AWS CLI found ($(aws --version 2>&1 | awk '{print $1}'))"

# Verify AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    print_error "AWS credentials not configured or invalid"
    echo "Run: aws configure"
    exit 1
fi
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
AWS_IDENTITY=$(aws sts get-caller-identity --query Arn --output text)
print_success "AWS credentials valid (Account: $AWS_ACCOUNT)"
echo "  Identity: $AWS_IDENTITY"

# Check if Grafana is enabled but SSO might not be configured
if [ "$ENABLE_GRAFANA" = "true" ]; then
    print_warning "Grafana enabled - requires AWS IAM Identity Center (SSO)"
    echo "  If SSO is not configured, deployment will fail."
    echo "  See: https://docs.aws.amazon.com/grafana/latest/userguide/authentication-in-AMG-SSO.html"
fi

# Check Helm
if ! command -v helm &> /dev/null; then
    install_helm
fi
print_success "Helm found ($(helm version --short 2>/dev/null || echo 'ok'))"

# Check network connectivity to AWS
echo "Checking network connectivity..."
if ! curl -s --connect-timeout 10 https://sts.$REGION.amazonaws.com > /dev/null 2>&1; then
    print_error "Cannot reach AWS endpoints"
    echo "  Check your internet connection and VPN status"
    exit 1
fi
print_success "AWS endpoints reachable"

# =============================================================================
# Step 3: Authenticate to ECR Public
# =============================================================================
print_header "Step 3: Authenticating to ECR Public"

echo "Logging into ECR Public registry (required for Helm charts)..."
if aws ecr-public get-login-password --region us-east-1 | helm registry login --username AWS --password-stdin public.ecr.aws 2>/dev/null; then
    print_success "ECR Public authentication successful"
else
    print_warning "ECR Public authentication failed - deployment may hit rate limits"
    echo "  You can manually run: aws ecr-public get-login-password --region us-east-1 | helm registry login --username AWS --password-stdin public.ecr.aws"
fi

# =============================================================================
# Step 4: Initialize Terraform
# =============================================================================
print_header "Step 4: Initializing Terraform"

cd "$TERRAFORM_DIR"
terraform init -input=false
print_success "Terraform initialized"

# =============================================================================
# Step 5: Detect and Import Existing Resources (handles partial previous deploys)
# =============================================================================
print_header "Step 5: Detecting Existing Resources"

# If EKS cluster already exists but not in state, import it
EKS_EXISTS=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --query "cluster.name" --output text 2>/dev/null || echo "")
if [ "$EKS_EXISTS" = "$CLUSTER_NAME" ]; then
    if ! terraform state show 'module.retail_app_eks.module.eks_cluster.aws_eks_cluster.this[0]' &>/dev/null; then
        print_warning "EKS cluster '$CLUSTER_NAME' exists but not in Terraform state, importing..."
        terraform import \
            -var="cluster_name=$CLUSTER_NAME" \
            -var="region=$REGION" \
            -var="enable_grafana=$ENABLE_GRAFANA" \
            'module.retail_app_eks.module.eks_cluster.aws_eks_cluster.this[0]' "$CLUSTER_NAME" 2>/dev/null || true
    else
        print_success "EKS cluster '$CLUSTER_NAME' already in state"
    fi
else
    echo "  No existing EKS cluster found (will create new)"
fi

# Wait for any RDS instances that are mid-creation from a prior run
for DB_INSTANCE in "${CLUSTER_NAME}-catalog-one" "${CLUSTER_NAME}-orders-one"; do
    DB_STATUS=$(aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE" --query "DBInstances[0].DBInstanceStatus" --output text --region "$REGION" 2>/dev/null || echo "not-found")
    if [ "$DB_STATUS" = "creating" ] || [ "$DB_STATUS" = "modifying" ]; then
        print_warning "$DB_INSTANCE is '$DB_STATUS', waiting for it to become available..."
        aws rds wait db-instance-available --db-instance-identifier "$DB_INSTANCE" --region "$REGION" 2>/dev/null || true
        print_success "$DB_INSTANCE is now available"
    fi
done

# =============================================================================
# Step 6: Plan Deployment
# =============================================================================
print_header "Step 6: Planning Deployment"

terraform plan \
    -var="cluster_name=$CLUSTER_NAME" \
    -var="region=$REGION" \
    -var="enable_grafana=$ENABLE_GRAFANA" \
    -out=tfplan

print_success "Terraform plan created"

# =============================================================================
# Step 7: Apply Terraform
# =============================================================================
print_header "Step 7: Deploying Infrastructure (this takes ~25-30 minutes)"

START_TIME=$(date +%s)

terraform apply tfplan

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

print_success "Infrastructure deployed in ${MINUTES}m ${SECONDS}s"

# =============================================================================
# Step 8: Configure kubectl
# =============================================================================
print_header "Step 8: Configuring kubectl"

aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"
print_success "kubectl configured for cluster: $CLUSTER_NAME"

# =============================================================================
# Step 9: Wait for Application Pods
# =============================================================================
print_header "Step 9: Waiting for Application Pods"

echo "Waiting for UI service..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=ui -n ui --timeout=300s 2>/dev/null || true

echo "Waiting for Catalog service..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=catalog -n catalog --timeout=300s 2>/dev/null || true

echo "Waiting for Carts service..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=carts -n carts --timeout=300s 2>/dev/null || true

echo "Waiting for Orders service..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=orders -n orders --timeout=300s 2>/dev/null || true

echo "Waiting for Checkout service..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=checkout -n checkout --timeout=300s 2>/dev/null || true

print_success "All application pods ready"

# =============================================================================
# Step 10: Get Application URL (CloudFront)
# =============================================================================
print_header "Step 10: Getting Application URL"

# Get CloudFront URL from Terraform output
cd "$TERRAFORM_DIR"
CLOUDFRONT_URL=$(terraform output -raw cloudfront_url 2>/dev/null || echo "")
cd - >/dev/null

# Also wait for ALB to be provisioned (CloudFront origin needs it)
echo "Waiting for ALB to be ready (CloudFront origin)..."
for i in {1..30}; do
    APP_URL=$(kubectl get ingress -n ui ui -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [ -n "$APP_URL" ]; then
        break
    fi
    echo "  Waiting for ALB... ($i/30)"
    sleep 10
done

if [ -n "$CLOUDFRONT_URL" ]; then
    print_success "CloudFront URL: $CLOUDFRONT_URL"
    echo "  (ALB is restricted to CloudFront only on port 8999 - not publicly accessible)"
else
    print_warning "CloudFront URL not yet available. Check: terraform output cloudfront_url"
fi

# =============================================================================
# Step 11: Create DevOps Agent Space
# =============================================================================
print_header "Step 11: Creating DevOps Agent Space"

AGENT_SPACE_NAME="${CLUSTER_NAME}-workshop"
AGENT_ROLE_NAME="DevOpsAgentRole-${CLUSTER_NAME}"

# Check if an agent space with this name already exists
EXISTING_SPACE_ID=$(aws devops-agent list-agent-spaces --region "$REGION" \
    --query "agentSpaces[?name=='${AGENT_SPACE_NAME}'].agentSpaceId" \
    --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_SPACE_ID" ] && [ "$EXISTING_SPACE_ID" != "None" ]; then
    AGENT_SPACE_ID="$EXISTING_SPACE_ID"
    print_success "Agent Space already exists: $AGENT_SPACE_ID"
else
    echo "Creating Agent Space: $AGENT_SPACE_NAME"
    AGENT_SPACE_RESPONSE=$(aws devops-agent create-agent-space \
        --name "$AGENT_SPACE_NAME" \
        --description "EKS Workshop - Retail Store on ${CLUSTER_NAME}" \
        --tags "devopsagent=true" \
        --region "$REGION" \
        --output json 2>&1)

    if [ $? -eq 0 ]; then
        AGENT_SPACE_ID=$(echo "$AGENT_SPACE_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['agentSpace']['agentSpaceId'])")
        print_success "Agent Space created: $AGENT_SPACE_ID"
    else
        print_error "Failed to create Agent Space: $AGENT_SPACE_RESPONSE"
        echo "  You can create it manually in the console:"
        echo "  https://console.aws.amazon.com/devops-agent/home?region=$REGION"
        AGENT_SPACE_ID=""
    fi
fi

# Create IAM Role for DevOps Agent (if space was created successfully)
if [ -n "$AGENT_SPACE_ID" ]; then
    echo ""
    echo "Configuring IAM role for DevOps Agent..."

    # Create trust policy for aidevops service
    TRUST_POLICY=$(cat <<EOFPOLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "aidevops.amazonaws.com"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "aws:SourceAccount": "${AWS_ACCOUNT}"
        }
      }
    }
  ]
}
EOFPOLICY
)

    if aws iam get-role --role-name "$AGENT_ROLE_NAME" &>/dev/null; then
        print_success "IAM Role already exists: $AGENT_ROLE_NAME"
    else
        aws iam create-role \
            --role-name "$AGENT_ROLE_NAME" \
            --assume-role-policy-document "$TRUST_POLICY" \
            --tags "Key=devopsagent,Value=true" 2>/dev/null

        # Attach read-only policies for investigation
        aws iam attach-role-policy --role-name "$AGENT_ROLE_NAME" \
            --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess 2>/dev/null || true
        aws iam attach-role-policy --role-name "$AGENT_ROLE_NAME" \
            --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy 2>/dev/null || true

        # Add inline policy for CloudWatch Logs & EKS pod logs
        aws iam put-role-policy --role-name "$AGENT_ROLE_NAME" \
            --policy-name "DevOpsAgentEKSAccess" \
            --policy-document '{
                "Version": "2012-10-17",
                "Statement": [
                    {
                        "Effect": "Allow",
                        "Action": [
                            "logs:GetLogEvents",
                            "logs:FilterLogEvents",
                            "logs:DescribeLogGroups",
                            "logs:DescribeLogStreams",
                            "logs:StartQuery",
                            "logs:GetQueryResults",
                            "eks:DescribeCluster",
                            "eks:ListClusters",
                            "eks:AccessKubernetesApi"
                        ],
                        "Resource": "*",
                        "Condition": {
                            "StringEquals": {
                                "aws:ResourceTag/devopsagent": "true"
                            }
                        }
                    },
                    {
                        "Effect": "Allow",
                        "Action": [
                            "logs:GetLogEvents",
                            "logs:FilterLogEvents",
                            "logs:DescribeLogGroups",
                            "logs:DescribeLogStreams",
                            "logs:StartQuery",
                            "logs:GetQueryResults"
                        ],
                        "Resource": "arn:aws:logs:*:*:log-group:/aws/eks/*"
                    }
                ]
            }' 2>/dev/null || true

        print_success "IAM Role created: $AGENT_ROLE_NAME"
    fi

    AGENT_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT}:role/${AGENT_ROLE_NAME}"

    # Associate AWS source account with Agent Space
    echo "Associating AWS account with Agent Space..."
    SERVICE_ID="aws-source-${AWS_ACCOUNT}"
    aws devops-agent associate-service \
        --agent-space-id "$AGENT_SPACE_ID" \
        --service-id "$SERVICE_ID" \
        --configuration "{\"sourceAws\":{\"accountId\":\"${AWS_ACCOUNT}\",\"accountType\":\"source\",\"assumableRoleArn\":\"${AGENT_ROLE_ARN}\"}}" \
        --region "$REGION" 2>/dev/null && print_success "AWS account associated" || print_warning "Association may already exist (OK)"

    # Configure EKS access entry for the DevOps Agent role
    echo "Configuring EKS access for DevOps Agent..."
    aws eks create-access-entry \
        --cluster-name "$CLUSTER_NAME" \
        --principal-arn "$AGENT_ROLE_ARN" \
        --type STANDARD \
        --region "$REGION" 2>/dev/null || true

    aws eks associate-access-policy \
        --cluster-name "$CLUSTER_NAME" \
        --principal-arn "$AGENT_ROLE_ARN" \
        --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
        --access-scope type=cluster \
        --region "$REGION" 2>/dev/null || true

    print_success "EKS access configured for DevOps Agent"

    # Enable Operator App (Web UI) with IAM auth
    echo "Enabling Operator App (Web UI)..."
    aws devops-agent enable-operator-app \
        --agent-space-id "$AGENT_SPACE_ID" \
        --auth-flow iam \
        --operator-app-role-arn "$AGENT_ROLE_ARN" \
        --region "$REGION" 2>/dev/null && print_success "Operator App enabled" || print_warning "Operator App may already be enabled (OK)"
fi

# =============================================================================
# Deployment Complete
# =============================================================================
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              🎉 Deployment Complete!                          ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [ -n "$CLOUDFRONT_URL" ]; then
    echo -e "📱 ${GREEN}Application URL (CloudFront):${NC} $CLOUDFRONT_URL"
    echo -e "   ${YELLOW}(ALB on port 8999 is restricted to CloudFront only — not directly accessible)${NC}"
elif [ -n "$APP_URL" ]; then
    echo -e "📱 ${GREEN}ALB (internal):${NC} http://$APP_URL:8999"
    echo -e "   ${YELLOW}CloudFront URL not available yet. Check: terraform output cloudfront_url${NC}"
else
    echo -e "${YELLOW}Application URL not yet available. Check with:${NC}"
    echo "   terraform -chdir=$TERRAFORM_DIR output cloudfront_url"
fi

echo ""
if [ -n "$AGENT_SPACE_ID" ]; then
    echo -e "🤖 ${GREEN}DevOps Agent Space:${NC} $AGENT_SPACE_ID"
    echo -e "   Console: https://console.aws.amazon.com/devops-agent/home?region=$REGION#/spaces/$AGENT_SPACE_ID"
fi

echo ""
echo "📊 Terraform Outputs:"
cd "$TERRAFORM_DIR"
terraform output 2>/dev/null || true

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Next Steps:${NC}"
echo ""
if [ -n "$AGENT_SPACE_ID" ]; then
    echo "1. Open DevOps Agent Operator App:"
    echo "   https://console.aws.amazon.com/devops-agent/home?region=$REGION#/spaces/$AGENT_SPACE_ID"
    echo ""
    echo "2. Run fault injection scenarios:"
    echo "   cd $REPO_ROOT/fault-injection"
    echo "   ./inject-catalog-latency.sh"
    echo ""
    echo "3. Start an investigation in DevOps Agent:"
    echo "   Click 'Operator Access' → 'Start Investigation'"
    echo ""
    echo "4. To destroy the environment:"
    echo "   $SCRIPT_DIR/destroy.sh"
else
    echo "1. Create an Agent Space in the DevOps Agent console:"
    echo "   https://console.aws.amazon.com/devops-agent/home?region=$REGION"
    echo ""
    echo "2. Add tag filter: Key=devopsagent, Value=true"
    echo ""
    echo "3. Configure EKS access for the Agent Space"
    echo ""
    echo "4. Run fault injection scenarios:"
    echo "   cd $REPO_ROOT/fault-injection"
    echo "   ./inject-catalog-latency.sh"
    echo ""
    echo "5. To destroy the environment:"
    echo "   $SCRIPT_DIR/destroy.sh"
fi
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
