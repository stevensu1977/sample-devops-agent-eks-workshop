"""
Lambda-A: CloudWatch Alarm → DevOps Agent Investigation

Triggered by EventBridge when a CloudWatch Alarm transitions to ALARM state.
Creates a backlog task (investigation) in AWS DevOps Agent.
"""

import json
import os
import boto3

DEVOPS_AGENT_SPACE_ID = os.environ["DEVOPS_AGENT_SPACE_ID"]
REGION = os.environ.get("DEPLOY_REGION", os.environ.get("AWS_REGION", "us-east-1"))


def lambda_handler(event, context):
    detail = event.get("detail", {})
    state_value = detail.get("state", {}).get("value", "")

    if state_value != "ALARM":
        return {"statusCode": 200, "body": f"Skipped: state={state_value}"}

    alarm_name = detail.get("alarmName", "Unknown")
    reason = detail.get("state", {}).get("reason", "N/A")
    namespace = detail.get("configuration", {}).get("namespace", "")
    metrics = detail.get("configuration", {}).get("metrics", [])

    resource_id = ""
    if metrics:
        dims = metrics[0].get("metricStat", {}).get("metric", {}).get("dimensions", {})
        resource_id = dims.get("InstanceId", "") or dims.get("PodName", "") or dims.get("ClusterName", "")

    description = (
        f"CloudWatch Alarm '{alarm_name}' triggered.\n"
        f"Resource: {resource_id}\n"
        f"Namespace: {namespace}\n"
        f"Reason: {reason}\n\n"
        f"Please investigate the root cause of this alarm."
    )

    client = boto3.client("devops-agent", region_name=REGION)
    response = client.create_backlog_task(
        agentSpaceId=DEVOPS_AGENT_SPACE_ID,
        taskType="INVESTIGATION",
        title=f"Investigate: {alarm_name} - {resource_id}",
        priority="HIGH",
        description=description,
    )

    task = response["task"]
    print(f"Investigation created: taskId={task['taskId']}, executionId={task['executionId']}")

    return {
        "statusCode": 200,
        "body": json.dumps({
            "taskId": task["taskId"],
            "executionId": task["executionId"],
            "status": task["status"],
        }),
    }
