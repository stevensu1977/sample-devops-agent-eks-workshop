# 飞书集成完整配置指南

本文档说明如何将 AWS DevOps Agent 与飞书集成，通过 WebSocket 长连接实现交互式对话排查。

---

## 目录

- [架构说明](#架构说明)
- [前置条件](#前置条件)
- [Step 1: 创建飞书应用](#step-1-创建飞书应用)
- [Step 2: 配置飞书应用](#step-2-配置飞书应用)
- [Step 3: 发布应用](#step-3-发布应用)
- [Step 4: 获取飞书群 Chat ID](#step-4-获取飞书群-chat-id)
- [Step 5: 获取 DevOps Agent Space ID](#step-5-获取-devops-agent-space-id)
- [Step 6: 部署 Bot 到 EKS](#step-6-部署-bot-到-eks)
- [Step 7: 验证](#step-7-验证)
- [使用方式](#使用方式)
- [故障排查](#故障排查)
- [清理](#清理)

---

## 架构说明

```
┌──────────┐    WebSocket (outbound)     ┌──────────────────┐
│ 飞书用户 │◀───────────────────────────▶│  EKS Pod         │
│  @Bot    │     (wss://feishu.cn)       │  (feishu-bot)    │
└──────────┘                             └────────┬─────────┘
                                                  │ boto3
                                                  ▼
                                         ┌──────────────────┐
                                         │  DevOps Agent    │
                                         │  Chat API        │
                                         └──────────────────┘
```

**为什么用 WebSocket 而不是 Webhook？**

飞书（feishu.cn）服务器在中国境内，无法直接访问 AWS us-east-1 的 API Gateway。
WebSocket 模式下，EKS Pod **主动连接**飞书（出站），无需公网入口，绕过跨境网络限制。

---

## 前置条件

| 条件 | 验证 |
|------|------|
| EKS 环境已部署 | `kubectl get nodes` |
| DevOps Agent Space 已创建 | `aws devops-agent list-agent-spaces --region us-east-1` |
| 飞书企业管理员权限 | 可创建自建应用 |

---

## Step 1: 创建飞书应用

1. 访问 [飞书开放平台](https://open.feishu.cn/app)
2. 点击 **创建企业自建应用**
3. 填写名称（如 `DevOps Agent Bot`）→ 创建
4. 记录 **App ID** 和 **App Secret**（凭证与基础信息页面）

---

## Step 2: 配置飞书应用

### 2.1 开启机器人

左侧 → **应用功能** → **机器人** → 开启

### 2.2 添加权限

左侧 → **权限管理** → 搜索并开通：

| 权限 | 标识 |
|------|------|
| 获取与发送消息 | `im:message` |
| 以 Bot 身份发消息 | `im:message:send_as_bot` |
| 获取群组信息 | `im:chat:readonly` |

### 2.3 配置事件订阅（长连接模式）

1. 左侧 → **事件订阅**
2. 接收方式选择：**使用长连接接收事件**
3. 添加事件：`im.message.receive_v1`

> **重要**：必须选择"长连接"，不是"发送到开发者服务器"。长连接模式不需要填写 URL。

---

## Step 3: 发布应用

1. 左侧 → **版本管理与发布** → 创建版本 → 提交审核
2. 管理员审核通过后生效

---

## Step 4: 获取飞书群 Chat ID

1. 将 Bot 添加到目标飞书群（群设置 → 群机器人 → 添加）
2. 获取 Chat ID：

```bash
FEISHU_APP_ID="<your-app-id>"
FEISHU_APP_SECRET="<your-app-secret>"

TOKEN=$(curl -s -X POST 'https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal' \
  -H 'Content-Type: application/json' \
  -d "{\"app_id\":\"${FEISHU_APP_ID}\",\"app_secret\":\"${FEISHU_APP_SECRET}\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['tenant_access_token'])")

curl -s 'https://open.feishu.cn/open-apis/im/v1/chats' \
  -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys,json
for c in json.load(sys.stdin)['data']['items']:
    print(f\"  {c['name']:30s} → {c['chat_id']}\")"
```

---

## Step 5: 获取 DevOps Agent Space ID

```bash
aws devops-agent list-agent-spaces --region us-east-1 \
  --query "agentSpaces[*].{name:name,id:agentSpaceId}" --output table
```

---

## Step 6: 部署 Bot 到 EKS

```bash
export DEVOPS_AGENT_SPACE_ID="<space-id>"
export FEISHU_APP_ID="<app-id>"
export FEISHU_APP_SECRET="<app-secret>"
export FEISHU_CHAT_ID="<chat-id>"

cd feishu-integration
./deploy-k8s-bot.sh
```

部署完成后 Pod 会自动通过 WebSocket 连接到飞书。

---

## Step 7: 验证

```bash
# 确认 Pod 运行中
kubectl get pods -n feishu-bot

# 确认 WebSocket 连接成功
kubectl logs -n feishu-bot -l app=feishu-bot | grep "connected to wss"
```

在飞书群 @Bot 发消息，Bot 应在数秒内回复。

---

## 使用方式

### 交互对话

| 在飞书群发送 | 说明 |
|-------------|------|
| `@Bot 查看 EKS 集群健康状态` | 集群概览 |
| `@Bot Why is catalog slow?` | 排查性能 |
| `@Bot 检查有没有 pod 重启` | 资源问题 |
| `@Bot 分析 DynamoDB 性能` | 数据库排查 |
| `/reset` 或 `重置` | 重置对话上下文 |

### 多轮对话

同一会话保持上下文：

```
用户: @Bot 列出 catalog namespace 的 pods
Bot:  有 2 个 pods: catalog-xxx, catalog-yyy...

用户: @Bot 哪个 CPU 最高?
Bot:  catalog-xxx CPU 95%，有一个 stress sidecar...
```

---

## 故障排查

### Pod 没有收到消息

```bash
kubectl logs -n feishu-bot -l app=feishu-bot --tail=30
```

| 症状 | 原因 | 解决 |
|------|------|------|
| 无 WebSocket 连接日志 | pip 安装失败 | 检查网络/镜像 |
| connected 但无消息 | 事件订阅未选长连接 | 飞书平台改为"长连接" |
| connected 但无消息 | 未订阅 im.message.receive_v1 | 添加事件订阅 |
| connected 但无消息 | 应用未发布 | 提交审核发布 |

### DevOps Agent 调用失败

```bash
# 测试 Pod 内 API 调用
kubectl exec -n feishu-bot deploy/feishu-bot -- python3 -c "
import boto3
client = boto3.client('devops-agent', region_name='us-east-1')
print(client.list_agent_spaces())
"
```

如果报 `AccessDeniedException`，检查 IAM role：
```bash
aws iam get-role-policy --role-name FeishuBotPodRole-retail-store --policy-name DevOpsAgentChat
```

### 重启 Bot

```bash
kubectl rollout restart deployment/feishu-bot -n feishu-bot
```

---

## 清理

```bash
# 删除 EKS 资源
kubectl delete namespace feishu-bot

# 删除 IAM Role
aws iam delete-role-policy --role-name FeishuBotPodRole-retail-store --policy-name DevOpsAgentChat
aws iam delete-role --role-name FeishuBotPodRole-retail-store
```
