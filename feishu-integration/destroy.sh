#!/bin/bash
set -e

# Cleanup script for Feishu integration resources

REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_NAME="DevOpsAgentFeishuLambdaRole"

echo "=== Destroying Feishu Integration Resources ==="
echo ""

# Delete EventBridge rules
echo "Deleting EventBridge rules..."
aws events remove-targets --rule "devops-agent-alarm-trigger" --ids "trigger-investigation" --region "$REGION" 2>/dev/null || true
aws events delete-rule --name "devops-agent-alarm-trigger" --region "$REGION" 2>/dev/null || true
aws events remove-targets --rule "devops-agent-investigation-completed" --ids "notify-feishu" --region "$REGION" 2>/dev/null || true
aws events delete-rule --name "devops-agent-investigation-completed" --region "$REGION" 2>/dev/null || true
echo "  Done"

# Delete API Gateway
echo "Deleting API Gateway..."
API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='devops-agent-feishu-bot-api'].ApiId" --output text 2>/dev/null || echo "")
if [ -n "$API_ID" ] && [ "$API_ID" != "None" ]; then
    aws apigatewayv2 delete-api --api-id "$API_ID" 2>/dev/null || true
fi
echo "  Done"

# Delete Lambda functions
echo "Deleting Lambda functions..."
for func in devops-agent-trigger-investigation devops-agent-notify-feishu devops-agent-feishu-bot; do
    aws lambda delete-function --function-name "$func" --region "$REGION" 2>/dev/null || true
done
echo "  Done"

# Delete Lambda layer (optional - may be shared)
echo "Deleting boto3 layer..."
LAYER_VERSION=$(aws lambda list-layer-versions --layer-name "boto3-latest" --query "LayerVersions[0].Version" --output text 2>/dev/null || echo "None")
if [ "$LAYER_VERSION" != "None" ] && [ -n "$LAYER_VERSION" ]; then
    aws lambda delete-layer-version --layer-name "boto3-latest" --version-number "$LAYER_VERSION" 2>/dev/null || true
fi
echo "  Done"

# Delete IAM role
echo "Deleting IAM role..."
aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name DevOpsAgentAccess 2>/dev/null || true
aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || true
echo "  Done"

echo ""
echo "=== Feishu Integration Resources Destroyed ==="
