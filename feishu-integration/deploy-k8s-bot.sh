#!/bin/bash
set -e

# =============================================================================
# Deploy Feishu Bot to EKS (WebSocket long-connection mode)
#
# This solves the cross-border network issue: instead of Feishu servers
# connecting to our AWS endpoint (blocked by China firewall), our Pod
# connects TO Feishu via WebSocket (outbound connection, always works).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-retail-store}"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

print_header() { echo -e "\n${BLUE}=== $1 ===${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }

echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║    🤖 Feishu Bot (WebSocket) - Deploy to EKS                  ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"

# Validate vars
REQUIRED_VARS=(DEVOPS_AGENT_SPACE_ID FEISHU_APP_ID FEISHU_APP_SECRET FEISHU_CHAT_ID)
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        print_error "Missing: $var"
        echo "Required: export DEVOPS_AGENT_SPACE_ID=... FEISHU_APP_ID=... FEISHU_APP_SECRET=... FEISHU_CHAT_ID=..."
        exit 1
    fi
done

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# =============================================================================
print_header "Step 1: Create IAM Role for Feishu Bot Pod"

ROLE_NAME="FeishuBotPodRole-${CLUSTER_NAME}"
OIDC_PROVIDER=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
    --query "cluster.identity.oidc.issuer" --output text | sed 's|https://||')

# Trust policy for IRSA (IAM Roles for Service Accounts)
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_PROVIDER}:sub": "system:serviceaccount:feishu-bot:feishu-bot",
        "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF
)

if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
    print_success "Role exists: $ROLE_NAME"
else
    aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST_POLICY" >/dev/null
    print_success "Created role: $ROLE_NAME"
fi

# Add DevOps Agent permissions
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "DevOpsAgentChat" --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Action": ["aidevops:CreateChat","aidevops:SendMessage","aidevops:CreateBacklogTask","aidevops:ListJournalRecords"],
        "Resource": "*"
    }]
}' 2>/dev/null

ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"
print_success "IAM permissions configured"

# =============================================================================
print_header "Step 2: Build and push bot container image"

# Create a simple Dockerfile and build with docker or use inline kubectl
# For simplicity, we'll use a ConfigMap with the bot code and install deps at startup

# Create the bot code ConfigMap
kubectl create namespace feishu-bot 2>/dev/null || true

kubectl create configmap feishu-bot-code \
    --from-file=bot.py="$SCRIPT_DIR/k8s/bot.py" \
    --from-file=requirements.txt=/dev/stdin \
    -n feishu-bot --dry-run=client -o yaml <<REQS | kubectl apply -f -
lark-oapi>=1.4.0
boto3>=1.35.0
REQS

print_success "Bot code ConfigMap created"

# =============================================================================
print_header "Step 3: Deploy Bot to EKS"

# Apply the deployment with substituted values
sed -e "s|__DEVOPS_AGENT_SPACE_ID__|${DEVOPS_AGENT_SPACE_ID}|g" \
    -e "s|__REGION__|${REGION}|g" \
    -e "s|__FEISHU_APP_ID__|${FEISHU_APP_ID}|g" \
    -e "s|__FEISHU_APP_SECRET__|${FEISHU_APP_SECRET}|g" \
    -e "s|__FEISHU_CHAT_ID__|${FEISHU_CHAT_ID}|g" \
    -e "s|__ROLE_ARN__|${ROLE_ARN}|g" \
    "$SCRIPT_DIR/k8s/feishu-bot-deployment.yaml" | kubectl apply -f -

# Patch deployment to install pip packages at startup
kubectl patch deployment feishu-bot -n feishu-bot --type json -p '[{
  "op": "replace",
  "path": "/spec/template/spec/containers/0/command",
  "value": ["sh", "-c", "pip install --quiet lark-oapi boto3 && python3 /app/bot.py"]
}]' 2>/dev/null || true

print_success "Bot deployment applied"

# =============================================================================
print_header "Step 4: Wait for Pod to be ready"

kubectl rollout status deployment/feishu-bot -n feishu-bot --timeout=120s 2>/dev/null || true

echo ""
kubectl get pods -n feishu-bot

# =============================================================================
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║      🎉 Feishu Bot Deployed (WebSocket mode)                  ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "The bot connects TO Feishu via WebSocket (outbound)."
echo "No inbound endpoint needed - bypasses China firewall restrictions."
echo ""
echo "飞书开放平台配置："
echo "  1. 事件订阅方式选择：使用长连接接收事件"
echo "  2. 不需要填写请求地址（Request URL）"
echo "  3. 确保已订阅事件：im.message.receive_v1"
echo ""
echo "测试：在飞书群 @Bot 发送消息"
echo ""
echo "查看日志："
echo "  kubectl logs -f -n feishu-bot -l app=feishu-bot"
echo ""
echo "清理："
echo "  kubectl delete namespace feishu-bot"
