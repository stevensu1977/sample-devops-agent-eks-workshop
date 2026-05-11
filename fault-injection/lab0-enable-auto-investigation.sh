#!/bin/bash
set -e

# =============================================================================
# Lab 0 (Optional): Enable Auto-Investigation
#
# Creates CloudWatch Alarms for all fault injection scenarios (Lab 1-5).
# When a fault is injected, the alarm triggers automatically and creates
# a DevOps Agent investigation → results sent to Feishu.
#
# Flow:
#   Fault Injection → CloudWatch Alarm → EventBridge → Lambda
#     → DevOps Agent Investigation (auto)
#     → Investigation Completed → Feishu notification
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-retail-store}"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_header() { echo -e "\n${BLUE}=== $1 ===${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }

echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Lab 0: Enable Auto-Investigation for Fault Injection         ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "This creates CloudWatch Alarms that automatically trigger"
echo "DevOps Agent investigations when Lab 1-5 faults are injected."

# Validate required env var
if [ -z "$DEVOPS_AGENT_SPACE_ID" ]; then
    DEVOPS_AGENT_SPACE_ID=$(aws devops-agent list-agent-spaces --region "$REGION" \
        --query "agentSpaces[0].agentSpaceId" --output text 2>/dev/null || echo "")
    if [ -z "$DEVOPS_AGENT_SPACE_ID" ] || [ "$DEVOPS_AGENT_SPACE_ID" = "None" ]; then
        print_error "DEVOPS_AGENT_SPACE_ID not set and cannot be auto-detected"
        echo "  export DEVOPS_AGENT_SPACE_ID=<your-space-id>"
        exit 1
    fi
    print_warning "Auto-detected DEVOPS_AGENT_SPACE_ID=$DEVOPS_AGENT_SPACE_ID"
fi

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
FUNC_NAME="devops-agent-auto-investigator"
ROLE_NAME="AutoInvestigatorLambdaRole"
LAYER_NAME="boto3-latest"

# =============================================================================
print_header "Step 1: Deploy Auto-Investigator Lambda"

# IAM Role
if ! aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
    aws iam create-role --role-name "$ROLE_NAME" \
        --assume-role-policy-document '{
            "Version":"2012-10-17",
            "Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]
        }' > /dev/null
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "DevOpsAgentCreate" --policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Action":["aidevops:CreateBacklogTask"],"Resource":"*"}]
}'
ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"
sleep 8

# Lambda Layer
LAYER_ARN=$(aws lambda list-layer-versions --layer-name "$LAYER_NAME" \
    --query "LayerVersions[0].LayerVersionArn" --output text 2>/dev/null || echo "None")
if [ "$LAYER_ARN" = "None" ] || [ -z "$LAYER_ARN" ]; then
    TMPDIR=$(mktemp -d)
    python3 -m venv "$TMPDIR/.venv"
    "$TMPDIR/.venv/bin/pip" install boto3 -t "$TMPDIR/python" --upgrade --quiet
    cd "$TMPDIR" && zip -r /tmp/boto3-layer.zip python/ -q && cd "$SCRIPT_DIR"
    LAYER_ARN=$(aws lambda publish-layer-version --layer-name "$LAYER_NAME" \
        --zip-file fileb:///tmp/boto3-layer.zip --compatible-runtimes python3.12 \
        --query "LayerVersionArn" --output text)
    rm -rf "$TMPDIR" /tmp/boto3-layer.zip
fi

# Deploy Lambda
LAMBDA_DIR="$(dirname "$SCRIPT_DIR")/feishu-integration/lambda/auto_investigator"
cd "$LAMBDA_DIR"
zip -r /tmp/${FUNC_NAME}.zip lambda_function.py -q
cd "$SCRIPT_DIR"

ENV_VARS="Variables={DEVOPS_AGENT_SPACE_ID=$DEVOPS_AGENT_SPACE_ID,DEPLOY_REGION=$REGION}"

if aws lambda get-function --function-name "$FUNC_NAME" &>/dev/null; then
    aws lambda update-function-code --function-name "$FUNC_NAME" \
        --zip-file "fileb:///tmp/${FUNC_NAME}.zip" > /dev/null
    sleep 5
    aws lambda update-function-configuration --function-name "$FUNC_NAME" \
        --timeout 30 --layers "$LAYER_ARN" --environment "$ENV_VARS" > /dev/null 2>/dev/null || true
    print_success "Lambda updated: $FUNC_NAME"
else
    aws lambda create-function --function-name "$FUNC_NAME" \
        --runtime python3.12 --handler "lambda_function.lambda_handler" \
        --role "$ROLE_ARN" --zip-file "fileb:///tmp/${FUNC_NAME}.zip" \
        --timeout 30 --memory-size 128 --layers "$LAYER_ARN" \
        --environment "$ENV_VARS" > /dev/null
    print_success "Lambda created: $FUNC_NAME"
fi
rm -f "/tmp/${FUNC_NAME}.zip"

# =============================================================================
print_header "Step 2: Create CloudWatch Alarms for Lab 1-5"

# Lab 1: Catalog CPU High (detects CPU stress injection)
aws cloudwatch put-metric-alarm \
    --alarm-name "${CLUSTER_NAME}-catalog-cpu-high" \
    --alarm-description "Lab 1: Catalog service CPU utilization exceeds 80%" \
    --namespace "ContainerInsights" \
    --metric-name "pod_cpu_utilization" \
    --dimensions Name=ClusterName,Value="$CLUSTER_NAME" Name=Namespace,Value=catalog Name=Service,Value=catalog \
    --statistic Average \
    --period 60 \
    --evaluation-periods 2 \
    --threshold 80 \
    --comparison-operator GreaterThanThreshold \
    --treat-missing-data notBreaching \
    --region "$REGION" 2>/dev/null || \
aws cloudwatch put-metric-alarm \
    --alarm-name "${CLUSTER_NAME}-catalog-cpu-high" \
    --alarm-description "Lab 1: Catalog service CPU utilization exceeds 80%" \
    --namespace "ContainerInsights" \
    --metric-name "pod_cpu_utilization" \
    --dimensions Name=ClusterName,Value="$CLUSTER_NAME" Name=Namespace,Value=catalog \
    --statistic Average \
    --period 60 \
    --evaluation-periods 2 \
    --threshold 80 \
    --comparison-operator GreaterThanThreshold \
    --treat-missing-data notBreaching \
    --region "$REGION"
print_success "Alarm: ${CLUSTER_NAME}-catalog-cpu-high (Lab 1)"

# Lab 2: Cart Pod Restarts (detects OOMKill / CrashLoopBackOff)
aws cloudwatch put-metric-alarm \
    --alarm-name "${CLUSTER_NAME}-carts-pod-restarts" \
    --alarm-description "Lab 2: Carts pod restart count exceeds threshold" \
    --namespace "ContainerInsights" \
    --metric-name "pod_number_of_container_restarts" \
    --dimensions Name=ClusterName,Value="$CLUSTER_NAME" Name=Namespace,Value=carts \
    --statistic Maximum \
    --period 60 \
    --evaluation-periods 1 \
    --threshold 2 \
    --comparison-operator GreaterThanThreshold \
    --treat-missing-data notBreaching \
    --region "$REGION"
print_success "Alarm: ${CLUSTER_NAME}-carts-pod-restarts (Lab 2)"

# Lab 3: Catalog/Orders Pod Restarts (detects RDS connection failure)
aws cloudwatch put-metric-alarm \
    --alarm-name "${CLUSTER_NAME}-catalog-pod-restarts" \
    --alarm-description "Lab 3: Catalog pod restarts (RDS connectivity)" \
    --namespace "ContainerInsights" \
    --metric-name "pod_number_of_container_restarts" \
    --dimensions Name=ClusterName,Value="$CLUSTER_NAME" Name=Namespace,Value=catalog \
    --statistic Maximum \
    --period 60 \
    --evaluation-periods 1 \
    --threshold 2 \
    --comparison-operator GreaterThanThreshold \
    --treat-missing-data notBreaching \
    --region "$REGION"
print_success "Alarm: ${CLUSTER_NAME}-catalog-pod-restarts (Lab 3)"

# Lab 4: DynamoDB Throttling (detects stress test)
aws cloudwatch put-metric-alarm \
    --alarm-name "${CLUSTER_NAME}-dynamodb-throttled" \
    --alarm-description "Lab 4: DynamoDB throttled requests detected" \
    --namespace "AWS/DynamoDB" \
    --metric-name "ThrottledRequests" \
    --dimensions Name=TableName,Value="${CLUSTER_NAME}-carts" \
    --statistic Sum \
    --period 60 \
    --evaluation-periods 1 \
    --threshold 10 \
    --comparison-operator GreaterThanThreshold \
    --treat-missing-data notBreaching \
    --region "$REGION"
print_success "Alarm: ${CLUSTER_NAME}-dynamodb-throttled (Lab 4)"

# Lab 5: UI Pod Not Ready (detects network partition)
aws cloudwatch put-metric-alarm \
    --alarm-name "${CLUSTER_NAME}-ui-not-ready" \
    --alarm-description "Lab 5: UI pods not in Ready state" \
    --namespace "ContainerInsights" \
    --metric-name "pod_status_ready" \
    --dimensions Name=ClusterName,Value="$CLUSTER_NAME" Name=Namespace,Value=ui \
    --statistic Minimum \
    --period 60 \
    --evaluation-periods 2 \
    --threshold 1 \
    --comparison-operator LessThanThreshold \
    --treat-missing-data breaching \
    --region "$REGION"
print_success "Alarm: ${CLUSTER_NAME}-ui-not-ready (Lab 5)"

# =============================================================================
print_header "Step 3: Create EventBridge Rule (Alarm → Lambda)"

aws events put-rule \
    --name "devops-agent-auto-investigate-alarm" \
    --event-pattern "{
        \"source\": [\"aws.cloudwatch\"],
        \"detail-type\": [\"CloudWatch Alarm State Change\"],
        \"detail\": {
            \"state\": {\"value\": [\"ALARM\"]},
            \"alarmName\": [{\"prefix\": \"${CLUSTER_NAME}\"}]
        }
    }" --region "$REGION" > /dev/null

aws lambda add-permission \
    --function-name "$FUNC_NAME" \
    --statement-id "eventbridge-alarm-invoke" \
    --action "lambda:InvokeFunction" \
    --principal "events.amazonaws.com" \
    --source-arn "arn:aws:events:${REGION}:${AWS_ACCOUNT_ID}:rule/devops-agent-auto-investigate-alarm" 2>/dev/null || true

aws events put-targets \
    --rule "devops-agent-auto-investigate-alarm" \
    --targets "Id=auto-investigator,Arn=arn:aws:lambda:${REGION}:${AWS_ACCOUNT_ID}:function:${FUNC_NAME}" \
    --region "$REGION" > /dev/null

print_success "EventBridge: CloudWatch Alarm → $FUNC_NAME"

# =============================================================================
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  🎉 Lab 0 Complete: Auto-Investigation Enabled!               ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "CloudWatch Alarms created:"
echo "  • ${CLUSTER_NAME}-catalog-cpu-high        → Lab 1 (CPU stress)"
echo "  • ${CLUSTER_NAME}-carts-pod-restarts      → Lab 2 (Memory leak)"
echo "  • ${CLUSTER_NAME}-catalog-pod-restarts    → Lab 3 (RDS block)"
echo "  • ${CLUSTER_NAME}-dynamodb-throttled      → Lab 4 (DynamoDB stress)"
echo "  • ${CLUSTER_NAME}-ui-not-ready            → Lab 5 (Network partition)"
echo ""
echo "Flow:"
echo "  ./inject-catalog-latency.sh"
echo "    → CloudWatch Alarm triggers"
echo "    → Lambda auto-creates investigation"
echo "    → DevOps Agent investigates (10-20 min)"
echo "    → Feishu receives investigation report"
echo ""
echo "Monitor:"
echo "  aws logs tail /aws/lambda/$FUNC_NAME --follow --region $REGION"
echo ""
echo "Disable:"
echo "  ./lab0-disable-auto-investigation.sh"
