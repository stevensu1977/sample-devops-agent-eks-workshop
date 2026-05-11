"""
Lambda-C: Feishu Bot — Bidirectional Chat with DevOps Agent

Receives messages from Feishu bot (via API Gateway), forwards to DevOps Agent
Chat API, streams the response, and replies back to the Feishu conversation.

Feishu Bot Event subscription URL: API Gateway endpoint for this Lambda.
"""

import json
import hashlib
import os
import urllib.request
import urllib.error

import boto3

DEVOPS_AGENT_SPACE_ID = os.environ["DEVOPS_AGENT_SPACE_ID"]
FEISHU_APP_ID = os.environ["FEISHU_APP_ID"]
FEISHU_APP_SECRET = os.environ["FEISHU_APP_SECRET"]
FEISHU_VERIFICATION_TOKEN = os.environ.get("FEISHU_VERIFICATION_TOKEN", "")
FEISHU_ENCRYPT_KEY = os.environ.get("FEISHU_ENCRYPT_KEY", "")
REGION = os.environ.get("DEPLOY_REGION", os.environ.get("AWS_REGION", "us-east-1"))

# In-memory session store (per Lambda instance). For production, use DynamoDB.
# Key: feishu_chat_id -> devops_agent_execution_id
_sessions = {}


def get_tenant_access_token():
    url = "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal"
    payload = json.dumps({"app_id": FEISHU_APP_ID, "app_secret": FEISHU_APP_SECRET}).encode()
    req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read())
    return data["tenant_access_token"]


def reply_feishu_message(token, message_id, text):
    url = f"https://open.feishu.cn/open-apis/im/v1/messages/{message_id}/reply"
    payload = json.dumps({
        "msg_type": "text",
        "content": json.dumps({"text": text}),
    }).encode()
    req = urllib.request.Request(url, data=payload, headers={
        "Content-Type": "application/json",
        "Authorization": f"Bearer {token}",
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        print(f"Feishu reply error: {e.read().decode()}")
        raise


def send_feishu_message(token, chat_id, text):
    url = "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=chat_id"
    payload = json.dumps({
        "receive_id": chat_id,
        "msg_type": "text",
        "content": json.dumps({"text": text}),
    }).encode()
    req = urllib.request.Request(url, data=payload, headers={
        "Content-Type": "application/json",
        "Authorization": f"Bearer {token}",
    })
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())


def chat_with_devops_agent(chat_id, user_message):
    """Send message to DevOps Agent Chat API and collect the full response."""
    client = boto3.client("devops-agent", region_name=REGION)

    execution_id = _sessions.get(chat_id)

    if not execution_id:
        chat_resp = client.create_chat(
            agentSpaceId=DEVOPS_AGENT_SPACE_ID,
            userId=f"feishu-{chat_id}",
            userType="IAM",
        )
        execution_id = chat_resp["executionId"]
        _sessions[chat_id] = execution_id

    response = client.send_message(
        agentSpaceId=DEVOPS_AGENT_SPACE_ID,
        executionId=execution_id,
        content=user_message,
        userId=f"feishu-{chat_id}",
    )

    full_text = []
    for event in response.get("events", []):
        if "contentBlockDelta" in event:
            delta = event["contentBlockDelta"].get("delta", {})
            text_delta = delta.get("textDelta", {}).get("text", "")
            if text_delta:
                full_text.append(text_delta)
        elif "responseFailed" in event:
            error_msg = event["responseFailed"].get("error", {}).get("message", "Unknown error")
            full_text.append(f"\n[Error: {error_msg}]")
            # Reset session on failure
            _sessions.pop(chat_id, None)
            break

    return "".join(full_text) if full_text else "DevOps Agent did not return a response."


def lambda_handler(event, context):
    # Handle API Gateway proxy format
    if "body" in event:
        body = json.loads(event["body"]) if isinstance(event["body"], str) else event["body"]
    else:
        body = event

    # Feishu URL verification challenge
    if "challenge" in body:
        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"challenge": body["challenge"]}),
        }

    # Feishu event schema v2.0
    header = body.get("header", {})
    event_type = header.get("event_type", "")

    if event_type != "im.message.receive_v1":
        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"code": 0, "msg": "ignored"}),
        }

    event_data = body.get("event", {})
    message = event_data.get("message", {})
    chat_id = message.get("chat_id", "")
    message_id = message.get("message_id", "")
    msg_type = message.get("message_type", "")

    # Only handle text messages
    if msg_type != "text":
        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"code": 0, "msg": "non-text ignored"}),
        }

    content = json.loads(message.get("content", "{}"))
    user_text = content.get("text", "").strip()

    # Remove @bot mention prefix
    if user_text.startswith("@"):
        parts = user_text.split(" ", 1)
        user_text = parts[1] if len(parts) > 1 else ""

    if not user_text:
        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"code": 0, "msg": "empty message"}),
        }

    # Handle special commands
    if user_text.lower() in ("/reset", "/new", "重置", "新对话"):
        _sessions.pop(chat_id, None)
        token = get_tenant_access_token()
        reply_feishu_message(token, message_id, "会话已重置。请发送新的问题开始调查。")
        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"code": 0, "msg": "session reset"}),
        }

    # Forward to DevOps Agent
    try:
        agent_response = chat_with_devops_agent(chat_id, user_text)
    except Exception as e:
        print(f"DevOps Agent error: {e}")
        agent_response = f"调查请求处理失败: {str(e)}\n\n请稍后重试，或发送 /reset 重置会话。"

    # Truncate if response is too long for Feishu
    if len(agent_response) > 4000:
        agent_response = agent_response[:4000] + "\n\n... (回复过长已截断)"

    token = get_tenant_access_token()
    reply_feishu_message(token, message_id, agent_response)

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"code": 0, "msg": "ok"}),
    }
