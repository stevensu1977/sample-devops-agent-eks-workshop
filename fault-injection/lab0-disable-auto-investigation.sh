#!/bin/bash
set -e

# Disable Lab 0: Remove auto-investigation alarms and Lambda

REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-retail-store}"
FUNC_NAME="devops-agent-auto-investigator"
ROLE_NAME="AutoInvestigatorLambdaRole"

echo "=== Disabling Auto-Investigation ==="

# Delete alarms
echo "Deleting CloudWatch Alarms..."
aws cloudwatch delete-alarms --alarm-names \
    "${CLUSTER_NAME}-catalog-cpu-high" \
    "${CLUSTER_NAME}-carts-pod-restarts" \
    "${CLUSTER_NAME}-catalog-pod-restarts" \
    "${CLUSTER_NAME}-dynamodb-throttled" \
    "${CLUSTER_NAME}-ui-not-ready" \
    --region "$REGION" 2>/dev/null || true

# Delete EventBridge rule
echo "Deleting EventBridge rule..."
aws events remove-targets --rule "devops-agent-auto-investigate-alarm" --ids "auto-investigator" --region "$REGION" 2>/dev/null || true
aws events delete-rule --name "devops-agent-auto-investigate-alarm" --region "$REGION" 2>/dev/null || true

# Delete Lambda
echo "Deleting Lambda..."
aws lambda delete-function --function-name "$FUNC_NAME" --region "$REGION" 2>/dev/null || true

# Delete IAM role
echo "Deleting IAM role..."
aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "DevOpsAgentCreate" 2>/dev/null || true
aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || true

echo ""
echo "=== Auto-Investigation Disabled ==="
echo "CloudWatch Alarms, Lambda, and EventBridge rule removed."
