"""
Feishu Bot - WebSocket long-connection mode.

Connects to Feishu via WebSocket (feishu SDK), receives messages,
forwards to AWS DevOps Agent Chat API, and replies back.

This runs as a Pod in EKS, solving the cross-border network issue
(China feishu.cn servers cannot reach us-east-1 API Gateway directly).
"""

import json
import os
import threading
import time
import logging

import lark_oapi as lark
from lark_oapi.api.im.v1 import *

import boto3

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger(__name__)

DEVOPS_AGENT_SPACE_ID = os.environ["DEVOPS_AGENT_SPACE_ID"]
REGION = os.environ.get("DEPLOY_REGION", os.environ.get("AWS_REGION", "us-east-1"))
FEISHU_APP_ID = os.environ["FEISHU_APP_ID"]
FEISHU_APP_SECRET = os.environ["FEISHU_APP_SECRET"]

# Session store: feishu_chat_id -> devops_agent_execution_id
_sessions = {}
_sessions_lock = threading.Lock()


def get_devops_agent_client():
    return boto3.client("devops-agent", region_name=REGION)


def chat_with_devops_agent(chat_id: str, user_message: str) -> str:
    client = get_devops_agent_client()

    with _sessions_lock:
        execution_id = _sessions.get(chat_id)

    if not execution_id:
        chat_resp = client.create_chat(
            agentSpaceId=DEVOPS_AGENT_SPACE_ID,
            userId=f"feishu-{chat_id}",
            userType="IAM",
        )
        execution_id = chat_resp["executionId"]
        with _sessions_lock:
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
            with _sessions_lock:
                _sessions.pop(chat_id, None)
            break

    return "".join(full_text) if full_text else "DevOps Agent did not return a response."


def handle_message(event: P2ImMessageReceiveV1) -> None:
    """Handle incoming Feishu message event."""
    try:
        _handle_message_inner(event)
    except Exception as e:
        logger.error(f"Unhandled error in handle_message: {type(e).__name__}: {e}", exc_info=True)


def _handle_message_inner(event: P2ImMessageReceiveV1) -> None:
    msg = event.event.message
    chat_id = msg.chat_id
    message_id = msg.message_id
    msg_type = msg.message_type

    if msg_type != "text":
        return

    content = json.loads(msg.content)
    user_text = content.get("text", "").strip()

    # Remove @bot mention
    if "@_user" in user_text:
        parts = user_text.split(" ", 1)
        user_text = parts[-1].strip() if len(parts) > 1 else ""
    elif user_text.startswith("@"):
        parts = user_text.split(" ", 1)
        user_text = parts[1].strip() if len(parts) > 1 else ""

    if not user_text:
        return

    # Handle reset commands
    if user_text.lower() in ("/reset", "/new", "重置", "新对话"):
        with _sessions_lock:
            _sessions.pop(chat_id, None)
        reply_text(message_id, "会话已重置。请发送新的问题开始调查。")
        return

    # Forward to DevOps Agent
    logger.info(f"Forwarding to DevOps Agent: chat_id={chat_id}, text={user_text[:50]}...")
    try:
        agent_response = chat_with_devops_agent(chat_id, user_text)
        logger.info(f"Agent response received: {len(agent_response)} chars")
    except Exception as e:
        logger.error(f"DevOps Agent error: {type(e).__name__}: {e}", exc_info=True)
        agent_response = f"调查请求处理失败: {str(e)}\n\n请稍后重试，或发送 /reset 重置会话。"

    if len(agent_response) > 4000:
        agent_response = agent_response[:4000] + "\n\n... (回复过长已截断)"

    try:
        reply_text(message_id, agent_response)
        logger.info(f"Reply sent to message_id={message_id}")
    except Exception as e:
        logger.error(f"Reply failed: {type(e).__name__}: {e}", exc_info=True)


def reply_text(message_id: str, text: str):
    """Reply to a Feishu message."""
    client = lark.Client.builder().app_id(FEISHU_APP_ID).app_secret(FEISHU_APP_SECRET).build()

    content = json.dumps({"text": text})
    req = ReplyMessageRequest.builder() \
        .message_id(message_id) \
        .request_body(ReplyMessageRequestBody.builder()
            .msg_type("text")
            .content(content)
            .build()) \
        .build()

    resp = client.im.v1.message.reply(req)
    if not resp.success():
        logger.error(f"Reply failed: code={resp.code}, msg={resp.msg}")


def main():
    logger.info("Starting Feishu Bot (WebSocket long-connection mode)")
    logger.info(f"Agent Space: {DEVOPS_AGENT_SPACE_ID}, Region: {REGION}")

    # Create Lark/Feishu event dispatcher
    event_handler = lark.EventDispatcherHandler.builder("", "") \
        .register_p2_im_message_receive_v1(handle_message) \
        .build()

    # Use WebSocket client (long connection - no need for public endpoint)
    cli = lark.ws.Client(
        FEISHU_APP_ID,
        FEISHU_APP_SECRET,
        event_handler=event_handler,
        log_level=lark.LogLevel.INFO,
    )

    cli.start()


if __name__ == "__main__":
    main()
