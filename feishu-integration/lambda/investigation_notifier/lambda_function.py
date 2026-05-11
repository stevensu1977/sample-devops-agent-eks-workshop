"""
Investigation Notifier: DevOps Agent Investigation Completed → Feishu

Triggered by EventBridge when DevOps Agent completes an investigation.
Fetches the investigation summary and sends it to the Feishu group chat.
"""

import json
import os
import urllib.request

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


def send_feishu_post(token, chat_id, title, content_blocks):
    url = "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=chat_id"
    content = {
        "zh_cn": {
            "title": title,
            "content": content_blocks,
        }
    }
    payload = json.dumps({
        "receive_id": chat_id,
        "msg_type": "post",
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

    summary = ""
    findings = []

    for record in response.get("records", []):
        record_type = record.get("recordType", "")
        if record_type == "investigation_summary_md":
            summary = record.get("content", "")
        elif record_type == "finding":
            findings.append(record.get("content", ""))

    if not summary and findings:
        summary = "\n\n".join(findings)

    return summary or "No investigation summary available."


STATUS_EMOJI = {
    "Investigation Created": "🆕",
    "Investigation In Progress": "🔄",
    "Investigation Completed": "✅",
    "Investigation Failed": "❌",
}

STATUS_TEXT = {
    "Investigation Created": "调查已创建",
    "Investigation In Progress": "正在调查中...",
    "Investigation Completed": "调查完成",
    "Investigation Failed": "调查失败",
}


def lambda_handler(event, context):
    detail = event.get("detail", {})
    metadata = detail.get("metadata", {})
    data = detail.get("data", {})
    detail_type = event.get("detail-type", "")

    execution_id = metadata.get("execution_id", "")
    task_id = metadata.get("task_id", "")
    priority = data.get("priority", "UNKNOWN")
    status = data.get("status", "UNKNOWN")

    print(f"Event: {detail_type}, task_id={task_id}, status={status}, priority={priority}")

    emoji = STATUS_EMOJI.get(detail_type, "🔍")
    status_cn = STATUS_TEXT.get(detail_type, detail_type)

    token = get_tenant_access_token()

    # For completed investigations, fetch the full summary
    if detail_type == "Investigation Completed":
        summary = get_investigation_summary(execution_id)

        # Send header message
        title = f"{emoji} 调查完成 [{priority}]"
        header_blocks = [
            [{"tag": "text", "text": f"Task ID: {task_id}"}],
            [{"tag": "text", "text": f"Priority: {priority} | Status: {status}"}],
        ]
        send_feishu_post(token, FEISHU_CHAT_ID, title, header_blocks)

        # Send summary in chunks if too long (Feishu text block limit ~30000 chars)
        MAX_CHUNK = 25000
        if len(summary) <= MAX_CHUNK:
            summary_blocks = [[{"tag": "text", "text": summary}]]
            send_feishu_post(token, FEISHU_CHAT_ID, "━━━ 调查摘要 ━━━", summary_blocks)
        else:
            part = 1
            while summary:
                chunk = summary[:MAX_CHUNK]
                summary = summary[MAX_CHUNK:]
                chunk_title = f"━━━ 调查摘要 ({part}) ━━━"
                send_feishu_post(token, FEISHU_CHAT_ID, chunk_title, [[{"tag": "text", "text": chunk}]])
                part += 1
    else:
        # For intermediate events, send a short status update
        title = f"{emoji} {status_cn} [{priority}]"
        content_blocks = [
            [{"tag": "text", "text": f"Task ID: {task_id}"}],
            [{"tag": "text", "text": f"状态: {status_cn}"}],
            [{"tag": "text", "text": f"Priority: {priority}"}],
        ]
        send_feishu_post(token, FEISHU_CHAT_ID, title, content_blocks)

    print(f"Feishu notification sent: {detail_type}, task_id={task_id}")
    return {"statusCode": 200}
