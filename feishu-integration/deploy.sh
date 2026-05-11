#!/bin/bash
set -e

# =============================================================================
# Feishu Integration Deployment Script
# Deploys Lambda functions, EventBridge rules, and API Gateway for Feishu bot
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() { echo -e "\n${BLUE}=== $1 ===${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }

# =============================================================================
# Configuration
# =============================================================================
echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║       🤖 Feishu + DevOps Agent Integration Deployment        ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"

REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-retail-store}"
ROLE_NAME="DevOpsAgentFeishuLambdaRole"
LAYER_NAME="boto3-latest"

# Validate required environment variables
REQUIRED_VARS=(DEVOPS_AGENT_SPACE_ID FEISHU_APP_ID FEISHU_APP_SECRET FEISHU_CHAT_ID)
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        print_error "Missing required environment variable: $var"
        echo ""
        echo "Required environment variables:"
        echo "  export DEVOPS_AGENT_SPACE_ID=<your-agent-space-id>"
        echo "  export FEISHU_APP_ID=<your-feishu-app-id>"
        echo "  export FEISHU_APP_SECRET=<your-feishu-app-secret>"
        echo "  export FEISHU_CHAT_ID=<your-feishu-chat-id>"
        echo ""
        echo "Optional:"
        echo "  export FEISHU_VERIFICATION_TOKEN=<feishu-event-verification-token>"
        echo "  export FEISHU_ENCRYPT_KEY=<feishu-event-encrypt-key>"
        echo "  export AWS_REGION=us-east-1"
        exit 1
    fi
done

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
print_success "AWS Account: $AWS_ACCOUNT_ID, Region: $REGION"

# =============================================================================
# Step 1: Create IAM Role
# =============================================================================
print_header "Step 1: Creating IAM Role"

if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
    print_warning "Role $ROLE_NAME already exists, skipping creation"
else
    aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document "file://$SCRIPT_DIR/iam/lambda-role-trust.json"
    print_success "Created role: $ROLE_NAME"
fi

aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true

aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name DevOpsAgentAccess \
    --policy-document "file://$SCRIPT_DIR/iam/devops-agent-policy.json"

print_success "IAM permissions configured"

ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"

# Wait for role to propagate
sleep 10

# =============================================================================
# Step 2: Create/Update Lambda Layer (latest boto3)
# =============================================================================
print_header "Step 2: Creating boto3 Lambda Layer"

LAYER_ARN=$(aws lambda list-layer-versions \
    --layer-name "$LAYER_NAME" \
    --query "LayerVersions[0].LayerVersionArn" \
    --output text 2>/dev/null || echo "None")

if [ "$LAYER_ARN" = "None" ] || [ -z "$LAYER_ARN" ]; then
    echo "Building boto3 layer..."
    TMPDIR=$(mktemp -d)
    mkdir -p "$TMPDIR/python"
    python3 -m venv "$TMPDIR/.venv"
    "$TMPDIR/.venv/bin/pip" install boto3 -t "$TMPDIR/python" --upgrade --no-cli-pager
    cd "$TMPDIR" && zip -r /tmp/boto3-layer.zip python/ -q
    cd "$SCRIPT_DIR"
    rm -rf "$TMPDIR"

    LAYER_ARN=$(aws lambda publish-layer-version \
        --layer-name "$LAYER_NAME" \
        --zip-file fileb:///tmp/boto3-layer.zip \
        --compatible-runtimes python3.12 \
        --query "LayerVersionArn" --output text)
    rm -f /tmp/boto3-layer.zip
    print_success "Layer created: $LAYER_ARN"
else
    print_success "Layer exists: $LAYER_ARN"
fi

# =============================================================================
# Step 3: Package and Deploy Lambda Functions
# =============================================================================
print_header "Step 3: Deploying Lambda Functions"

deploy_lambda() {
    local FUNC_NAME=$1
    local HANDLER=$2
    local SRC_DIR=$3
    local TIMEOUT=${4:-30}
    local ENV_VARS=$5

    echo "  Packaging $FUNC_NAME..."
    cd "$SRC_DIR"
    zip -r /tmp/${FUNC_NAME}.zip lambda_function.py -q
    cd "$SCRIPT_DIR"

    if aws lambda get-function --function-name "$FUNC_NAME" &>/dev/null; then
        aws lambda update-function-code \
            --function-name "$FUNC_NAME" \
            --zip-file "fileb:///tmp/${FUNC_NAME}.zip" --no-cli-pager
        aws lambda update-function-configuration \
            --function-name "$FUNC_NAME" \
            --timeout "$TIMEOUT" \
            --layers "$LAYER_ARN" \
            --environment "$ENV_VARS" --no-cli-pager 2>/dev/null || true
        print_success "  Updated: $FUNC_NAME"
    else
        aws lambda create-function \
            --function-name "$FUNC_NAME" \
            --runtime python3.12 \
            --handler "lambda_function.lambda_handler" \
            --role "$ROLE_ARN" \
            --zip-file "fileb:///tmp/${FUNC_NAME}.zip" \
            --timeout "$TIMEOUT" --memory-size 128 \
            --layers "$LAYER_ARN" \
            --environment "$ENV_VARS"
        print_success "  Created: $FUNC_NAME"
    fi

    rm -f "/tmp/${FUNC_NAME}.zip"
}

# Lambda-A: Trigger Investigation
deploy_lambda \
    "devops-agent-trigger-investigation" \
    "lambda_function.lambda_handler" \
    "$SCRIPT_DIR/lambda/trigger_investigation" \
    30 \
    "Variables={DEVOPS_AGENT_SPACE_ID=$DEVOPS_AGENT_SPACE_ID,DEPLOY_REGION=$REGION}"

# Lambda-B: Notify Feishu
deploy_lambda \
    "devops-agent-notify-feishu" \
    "lambda_function.lambda_handler" \
    "$SCRIPT_DIR/lambda/notify_feishu" \
    60 \
    "Variables={DEVOPS_AGENT_SPACE_ID=$DEVOPS_AGENT_SPACE_ID,FEISHU_APP_ID=$FEISHU_APP_ID,FEISHU_APP_SECRET=$FEISHU_APP_SECRET,FEISHU_CHAT_ID=$FEISHU_CHAT_ID,DEPLOY_REGION=$REGION}"

# Lambda-C: Feishu Bot (Chat API)
deploy_lambda \
    "devops-agent-feishu-bot" \
    "lambda_function.lambda_handler" \
    "$SCRIPT_DIR/lambda/feishu_bot" \
    120 \
    "Variables={DEVOPS_AGENT_SPACE_ID=$DEVOPS_AGENT_SPACE_ID,FEISHU_APP_ID=$FEISHU_APP_ID,FEISHU_APP_SECRET=$FEISHU_APP_SECRET,FEISHU_VERIFICATION_TOKEN=${FEISHU_VERIFICATION_TOKEN:-},FEISHU_ENCRYPT_KEY=${FEISHU_ENCRYPT_KEY:-},DEPLOY_REGION=$REGION}"

# =============================================================================
# Step 4: Create EventBridge Rules
# =============================================================================
print_header "Step 4: Creating EventBridge Rules"

# Rule 1: CloudWatch Alarm → Lambda-A
aws events put-rule \
    --name "devops-agent-alarm-trigger" \
    --event-pattern "{
        \"source\": [\"aws.cloudwatch\"],
        \"detail-type\": [\"CloudWatch Alarm State Change\"],
        \"detail\": {
            \"state\": {\"value\": [\"ALARM\"]},
            \"alarmName\": [{\"prefix\": \"${CLUSTER_NAME}\"}]
        }
    }" --region "$REGION" --no-cli-pager

aws lambda add-permission \
    --function-name "devops-agent-trigger-investigation" \
    --statement-id "eventbridge-alarm-invoke" \
    --action "lambda:InvokeFunction" \
    --principal "events.amazonaws.com" \
    --source-arn "arn:aws:events:${REGION}:${AWS_ACCOUNT_ID}:rule/devops-agent-alarm-trigger" 2>/dev/null || true

aws events put-targets \
    --rule "devops-agent-alarm-trigger" \
    --targets "Id=trigger-investigation,Arn=arn:aws:lambda:${REGION}:${AWS_ACCOUNT_ID}:function:devops-agent-trigger-investigation" \
    --region "$REGION" --no-cli-pager

print_success "Rule 1: CloudWatch Alarm → Lambda-A"

# Rule 2: Investigation Completed → Lambda-B
aws events put-rule \
    --name "devops-agent-investigation-completed" \
    --event-pattern '{
        "source": ["aws.aidevops"],
        "detail-type": ["Investigation Completed"]
    }' --region "$REGION" --no-cli-pager

aws lambda add-permission \
    --function-name "devops-agent-notify-feishu" \
    --statement-id "eventbridge-completed-invoke" \
    --action "lambda:InvokeFunction" \
    --principal "events.amazonaws.com" \
    --source-arn "arn:aws:events:${REGION}:${AWS_ACCOUNT_ID}:rule/devops-agent-investigation-completed" 2>/dev/null || true

aws events put-targets \
    --rule "devops-agent-investigation-completed" \
    --targets "Id=notify-feishu,Arn=arn:aws:lambda:${REGION}:${AWS_ACCOUNT_ID}:function:devops-agent-notify-feishu" \
    --region "$REGION" --no-cli-pager

print_success "Rule 2: Investigation Completed → Lambda-B (Feishu)"

# =============================================================================
# Step 5: Create API Gateway for Feishu Bot Webhook
# =============================================================================
print_header "Step 5: Creating API Gateway for Feishu Bot"

API_NAME="devops-agent-feishu-bot-api"

# Check if API already exists
API_ID=$(aws apigatewayv2 get-apis \
    --query "Items[?Name=='${API_NAME}'].ApiId" \
    --output text 2>/dev/null || echo "")

if [ -z "$API_ID" ] || [ "$API_ID" = "None" ]; then
    API_ID=$(aws apigatewayv2 create-api \
        --name "$API_NAME" \
        --protocol-type HTTP \
        --query "ApiId" --output text)
    print_success "Created API: $API_ID"
else
    print_warning "API exists: $API_ID"
fi

# Create Lambda integration
INTEGRATION_ID=$(aws apigatewayv2 create-integration \
    --api-id "$API_ID" \
    --integration-type AWS_PROXY \
    --integration-uri "arn:aws:lambda:${REGION}:${AWS_ACCOUNT_ID}:function:devops-agent-feishu-bot" \
    --payload-format-version "2.0" \
    --query "IntegrationId" --output text 2>/dev/null || echo "")

# Create route POST /webhook
aws apigatewayv2 create-route \
    --api-id "$API_ID" \
    --route-key "POST /webhook" \
    --target "integrations/$INTEGRATION_ID" --no-cli-pager 2>/dev/null || true

# Create/update default stage with auto-deploy
aws apigatewayv2 create-stage \
    --api-id "$API_ID" \
    --stage-name '$default' \
    --auto-deploy --no-cli-pager 2>/dev/null || true

# Allow API Gateway to invoke the Lambda
aws lambda add-permission \
    --function-name "devops-agent-feishu-bot" \
    --statement-id "apigateway-invoke" \
    --action "lambda:InvokeFunction" \
    --principal "apigateway.amazonaws.com" \
    --source-arn "arn:aws:execute-api:${REGION}:${AWS_ACCOUNT_ID}:${API_ID}/*/*" 2>/dev/null || true

WEBHOOK_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com/webhook"
print_success "API Gateway webhook: $WEBHOOK_URL"

# =============================================================================
# Deployment Complete
# =============================================================================
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║        🎉 Feishu Integration Deployed Successfully!           ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}Components deployed:${NC}"
echo "  • Lambda-A: devops-agent-trigger-investigation (CloudWatch → Agent)"
echo "  • Lambda-B: devops-agent-notify-feishu (Agent → Feishu notification)"
echo "  • Lambda-C: devops-agent-feishu-bot (Feishu ↔ Agent Chat)"
echo "  • EventBridge Rule 1: CloudWatch Alarm → Lambda-A"
echo "  • EventBridge Rule 2: Investigation Completed → Lambda-B"
echo "  • API Gateway: Feishu bot webhook endpoint"
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Next Steps:${NC}"
echo ""
echo "1. Configure Feishu Bot webhook URL:"
echo "   ${WEBHOOK_URL}"
echo ""
echo "2. In Feishu Developer Console (https://open.feishu.cn/app):"
echo "   a. Go to your bot app → Event Subscriptions"
echo "   b. Set Request URL to the webhook URL above"
echo "   c. Subscribe to event: im.message.receive_v1"
echo "   d. Add bot to your target group chat"
echo ""
echo "3. Test the bot:"
echo "   @YourBot What EC2 instances are running?"
echo "   @YourBot Why is the catalog service slow?"
echo "   @YourBot Check the health of my EKS pods"
echo ""
echo "4. Test auto-investigation:"
echo "   cd ../fault-injection && ./inject-catalog-latency.sh"
echo "   (Wait for CloudWatch alarm → auto investigation → Feishu notification)"
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
