"""
Auto Investigator: CloudWatch Alarm → DevOps Agent Investigation

Triggered by EventBridge when a CloudWatch Alarm transitions to ALARM state.
Automatically creates a backlog task (investigation) in AWS DevOps Agent.

Covers all Lab 1-5 fault injection scenarios:
- Lab 1: Catalog CPU stress (pod_cpu_utilization alarm)
- Lab 2: Cart memory leak / OOMKill (pod_restart alarm)
- Lab 3: RDS security group block (pod_restart alarm on catalog/orders)
- Lab 4: DynamoDB stress (detected via carts latency)
- Lab 5: Network partition (UI pod not ready)
"""

import json
import os
import boto3

DEVOPS_AGENT_SPACE_ID = os.environ["DEVOPS_AGENT_SPACE_ID"]
REGION = os.environ.get("DEPLOY_REGION", os.environ.get("AWS_REGION", "us-east-1"))


def lambda_handler(event, context):
    detail = event.get("detail", {})
    source = event.get("source", "")

    # Handle CloudWatch Alarm events
    if source == "aws.cloudwatch":
        return handle_cloudwatch_alarm(detail)

    # Handle EKS/K8s events from Container Insights
    print(f"Unhandled event source: {source}")
    return {"statusCode": 200, "body": "skipped"}


def handle_cloudwatch_alarm(detail):
    state_value = detail.get("state", {}).get("value", "")

    if state_value != "ALARM":
        print(f"Skipped: state={state_value}")
        return {"statusCode": 200, "body": f"skipped: {state_value}"}

    alarm_name = detail.get("alarmName", "Unknown")
    reason = detail.get("state", {}).get("reason", "N/A")
    namespace = detail.get("configuration", {}).get("namespace", "")

    # Extract dimensions from metrics
    metrics = detail.get("configuration", {}).get("metrics", [])
    dimensions = {}
    if metrics:
        metric_stat = metrics[0].get("metricStat", {})
        dims = metric_stat.get("metric", {}).get("dimensions", {})
        dimensions = dims
        if not namespace:
            namespace = metric_stat.get("metric", {}).get("namespace", "")

    # Build context-aware description
    service_name = dimensions.get("PodName", dimensions.get("Service", dimensions.get("Namespace", "")))
    cluster = dimensions.get("ClusterName", "retail-store")

    description = (
        f"CloudWatch Alarm '{alarm_name}' triggered ALARM state.\n\n"
        f"Cluster: {cluster}\n"
        f"Service/Pod: {service_name}\n"
        f"Namespace: {namespace}\n"
        f"Reason: {reason}\n\n"
        f"Dimensions: {json.dumps(dimensions)}\n\n"
        f"Please investigate the root cause. Check pod status, resource utilization, "
        f"logs, and any recent deployment changes that may have caused this issue."
    )

    # Determine priority based on alarm name patterns
    priority = "HIGH"
    if "critical" in alarm_name.lower() or "oomkill" in alarm_name.lower():
        priority = "CRITICAL"

    client = boto3.client("devops-agent", region_name=REGION)

    try:
        response = client.create_backlog_task(
            agentSpaceId=DEVOPS_AGENT_SPACE_ID,
            taskType="INVESTIGATION",
            title=f"Auto-Investigate: {alarm_name}",
            priority=priority,
            description=description,
        )
        task = response["task"]
        print(f"Investigation created: taskId={task['taskId']}, status={task['status']}, alarm={alarm_name}")
        return {
            "statusCode": 200,
            "body": json.dumps({"taskId": task["taskId"], "status": task["status"]}),
        }
    except Exception as e:
        print(f"Failed to create investigation: {type(e).__name__}: {e}")
        return {"statusCode": 500, "body": str(e)}
