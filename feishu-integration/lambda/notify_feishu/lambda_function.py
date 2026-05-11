"""
Lambda-B: Investigation Completed → Feishu Notification

Triggered by EventBridge when DevOps Agent completes an investigation.
Fetches the investigation summary and sends it to a Feishu group chat.
"""

import json
import os
import urllib.request
import urllib.error

import boto3

DEVOPS_AGENT_SPACE_ID = os.environ["DEVOPS_AGENT_SPACE_ID"]
FEISHU_APP_ID = os.environ["FEISHU_APP_ID"]
FEISHU_APP_SECRET = os.environ["FEISHU_APP_SECRET"]
FEISHU_CHAT_ID = os.environ["FEISHU_CHAT_ID"]
REGION = os.environ.get("DEPLOY_REGION", os.environ.get("AWS_REGION", "us-east-1"))


def get_tenant_access_token():
    url = "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal"
    payload = json.dumps({"app_id": FEISHU_APP_ID, "app_secret": FEISHU_APP_SECRET}).encode()
    req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read())
    if data.get("code") != 0:
        raise RuntimeError(f"Failed to get Feishu token: {data}")
    return data["tenant_access_token"]


def send_feishu_message(token, chat_id, msg_type, content):
    url = "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=chat_id"
    payload = json.dumps({
        "receive_id": chat_id,
        "msg_type": msg_type,
        "content": json.dumps(content),
    }).encode()
    req = urllib.request.Request(url, data=payload, headers={
        "Content-Type": "application/json",
        "Authorization": f"Bearer {token}",
    })
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.loads(resp.read())
    if data.get("code") != 0:
        print(f"Feishu send error: {data}")
    return data


def get_investigation_summary(execution_id):
    client = boto3.client("devops-agent", region_name=REGION)
    response = client.list_journal_records(
        agentSpaceId=DEVOPS_AGENT_SPACE_ID,
        executionId=execution_id,
    )
    for record in response.get("records", []):
        if record.get("recordType") == "investigation_summary_md":
            return record.get("content", "")
    return "No investigation summary available."


def lambda_handler(event, context):
    detail = event.get("detail", {})
    metadata = detail.get("metadata", {})
    data = detail.get("data", {})

    execution_id = metadata.get("execution_id", "")
    task_id = metadata.get("task_id", "")
    priority = data.get("priority", "UNKNOWN")
    status = data.get("status", "UNKNOWN")

    summary = get_investigation_summary(execution_id)

    # Truncate if too long for Feishu message (max ~30000 chars)
    if len(summary) > 4000:
        summary = summary[:4000] + "\n\n... (truncated, see full report in DevOps Agent console)"

    token = get_tenant_access_token()

    content = {
        "zh_cn": {
            "title": f"🔍 DevOps Agent 调查完成 [{priority}]",
            "content": [
                [{"tag": "text", "text": f"任务 ID: {task_id}"}],
                [{"tag": "text", "text": f"状态: {status}"}],
                [{"tag": "text", "text": ""}],
                [{"tag": "text", "text": "━━━ 调查摘要 ━━━"}],
                [{"tag": "text", "text": summary}],
            ],
        }
    }

    send_feishu_message(token, FEISHU_CHAT_ID, "post", content)
    print(f"Notification sent for task_id={task_id}")

    return {"statusCode": 200, "body": "Notification sent"}
