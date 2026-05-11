#!/bin/bash
set -e

# =============================================================================
# Deploy Investigation Notifier Lambda
# EventBridge (aws.aidevops / Investigation Completed) → Lambda → Feishu
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="${AWS_REGION:-us-east-1}"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

print_header() { echo -e "\n${BLUE}=== $1 ===${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }

echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  📢 Investigation Notifier - Deploy (Agent → Feishu)          ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"

# Validate
REQUIRED_VARS=(DEVOPS_AGENT_SPACE_ID FEISHU_APP_ID FEISHU_APP_SECRET FEISHU_CHAT_ID)
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        print_error "Missing: $var"
        exit 1
    fi
done

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
FUNC_NAME="devops-agent-investigation-notifier"
ROLE_NAME="InvestigationNotifierLambdaRole"
LAYER_NAME="boto3-latest"

# =============================================================================
print_header "Step 1: IAM Role"

if ! aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
    aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document '{
            "Version":"2012-10-17",
            "Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]
        }' > /dev/null
fi

aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true

aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "DevOpsAgentRead" --policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Action":["aidevops:ListJournalRecords","aidevops:GetBacklogTask"],"Resource":"*"}]
}'

ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"
print_success "IAM Role: $ROLE_NAME"
sleep 8

# =============================================================================
print_header "Step 2: Lambda Layer (boto3)"

LAYER_ARN=$(aws lambda list-layer-versions --layer-name "$LAYER_NAME" \
    --query "LayerVersions[0].LayerVersionArn" --output text 2>/dev/null || echo "None")

if [ "$LAYER_ARN" = "None" ] || [ -z "$LAYER_ARN" ]; then
    echo "Building boto3 layer..."
    TMPDIR=$(mktemp -d)
    python3 -m venv "$TMPDIR/.venv"
    "$TMPDIR/.venv/bin/pip" install boto3 -t "$TMPDIR/python" --upgrade --quiet
    cd "$TMPDIR" && zip -r /tmp/boto3-layer.zip python/ -q
    cd "$SCRIPT_DIR"
    rm -rf "$TMPDIR"
    LAYER_ARN=$(aws lambda publish-layer-version \
        --layer-name "$LAYER_NAME" \
        --zip-file fileb:///tmp/boto3-layer.zip \
        --compatible-runtimes python3.12 \
        --query "LayerVersionArn" --output text)
    rm -f /tmp/boto3-layer.zip
fi
print_success "Layer: $LAYER_ARN"

# =============================================================================
print_header "Step 3: Deploy Lambda"

cd "$SCRIPT_DIR/lambda/investigation_notifier"
zip -r /tmp/${FUNC_NAME}.zip lambda_function.py -q
cd "$SCRIPT_DIR"

ENV_VARS="Variables={DEVOPS_AGENT_SPACE_ID=$DEVOPS_AGENT_SPACE_ID,FEISHU_APP_ID=$FEISHU_APP_ID,FEISHU_APP_SECRET=$FEISHU_APP_SECRET,FEISHU_CHAT_ID=$FEISHU_CHAT_ID,DEPLOY_REGION=$REGION}"

if aws lambda get-function --function-name "$FUNC_NAME" &>/dev/null; then
    aws lambda update-function-code --function-name "$FUNC_NAME" \
        --zip-file "fileb:///tmp/${FUNC_NAME}.zip" > /dev/null
    sleep 5
    aws lambda update-function-configuration --function-name "$FUNC_NAME" \
        --timeout 60 --layers "$LAYER_ARN" --environment "$ENV_VARS" > /dev/null 2>/dev/null || true
    print_success "Updated: $FUNC_NAME"
else
    aws lambda create-function \
        --function-name "$FUNC_NAME" \
        --runtime python3.12 \
        --handler "lambda_function.lambda_handler" \
        --role "$ROLE_ARN" \
        --zip-file "fileb:///tmp/${FUNC_NAME}.zip" \
        --timeout 60 --memory-size 128 \
        --layers "$LAYER_ARN" \
        --environment "$ENV_VARS" > /dev/null
    print_success "Created: $FUNC_NAME"
fi
rm -f "/tmp/${FUNC_NAME}.zip"

# =============================================================================
print_header "Step 4: EventBridge Rule"

aws events put-rule \
    --name "devops-agent-investigation-completed" \
    --event-pattern '{
        "source": ["aws.aidevops"],
        "detail-type": ["Investigation Completed"]
    }' --region "$REGION" > /dev/null

aws lambda add-permission \
    --function-name "$FUNC_NAME" \
    --statement-id "eventbridge-invoke" \
    --action "lambda:InvokeFunction" \
    --principal "events.amazonaws.com" \
    --source-arn "arn:aws:events:${REGION}:${AWS_ACCOUNT_ID}:rule/devops-agent-investigation-completed" 2>/dev/null || true

aws events put-targets \
    --rule "devops-agent-investigation-completed" \
    --targets "Id=investigation-notifier,Arn=arn:aws:lambda:${REGION}:${AWS_ACCOUNT_ID}:function:${FUNC_NAME}" \
    --region "$REGION" > /dev/null

print_success "EventBridge: aws.aidevops → $FUNC_NAME"

# =============================================================================
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  🎉 Investigation Notifier Deployed!                          ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Flow:"
echo "  Fault Injection → DevOps Agent Investigation → Completed"
echo "  → EventBridge → Lambda → 飞书群通知"
echo ""
echo "Test:"
echo "  cd ../fault-injection && ./inject-catalog-latency.sh"
echo "  (Start investigation in DevOps Agent console)"
echo "  (Wait 10-20 min → Feishu receives investigation report)"
echo ""
echo "Logs:"
echo "  aws logs tail /aws/lambda/$FUNC_NAME --follow --region $REGION"
