# 飞书集成完整配置指南

本文档详细说明如何将 AWS DevOps Agent 与飞书集成，实现双向交互：
- **自动通知**：故障注入 → CloudWatch 告警 → DevOps Agent 自主调查 → 调查报告自动推送飞书群
- **交互对话**：在飞书群 @Bot 提问，通过 Chat API 实时与 DevOps Agent 对话排查

---

## 目录

- [架构概览](#架构概览)
- [前置条件](#前置条件)
- [Step 1: 创建飞书应用](#step-1-创建飞书应用)
- [Step 2: 配置飞书应用能力](#step-2-配置飞书应用能力)
- [Step 3: 发布飞书应用](#step-3-发布飞书应用)
- [Step 4: 获取飞书群 Chat ID](#step-4-获取飞书群-chat-id)
- [Step 5: 获取 DevOps Agent Space ID](#step-5-获取-devops-agent-space-id)
- [Step 6: 部署飞书集成](#step-6-部署飞书集成)
- [Step 7: 配置飞书 Webhook URL](#step-7-配置飞书-webhook-url)
- [Step 8: 验证集成](#step-8-验证集成)
- [使用方式](#使用方式)
- [故障排查](#故障排查)
- [环境变量参考](#环境变量参考)
- [安全建议](#安全建议)
- [清理](#清理)

---

## 架构概览

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     自动调查流程 (Event-Driven)                               │
│                                                                             │
│   ┌──────────┐    ┌────────────┐    ┌──────────┐    ┌──────────────────┐   │
│   │CloudWatch│───▶│EventBridge │───▶│ Lambda-A │───▶│  DevOps Agent    │   │
│   │  Alarm   │    │  Rule-1    │    │ (trigger)│    │ (自主调查 5-15min)│   │
│   └──────────┘    └────────────┘    └──────────┘    └────────┬─────────┘   │
│                                                               │             │
│                                                               ▼             │
│   ┌──────────┐    ┌────────────┐    ┌──────────┐    ┌──────────────────┐   │
│   │ 飞书群   │◀───│  Lambda-B  │◀───│EventBridge│◀───│  Investigation   │   │
│   │ (通知)   │    │  (notify)  │    │  Rule-2  │    │   Completed      │   │
│   └──────────┘    └────────────┘    └────────────┘  └──────────────────┘   │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                     交互式对话 (Chat API)                                     │
│                                                                             │
│   ┌──────────┐    ┌────────────┐    ┌──────────┐    ┌──────────────────┐   │
│   │ 飞书用户 │───▶│API Gateway │───▶│ Lambda-C │◀──▶│  DevOps Agent    │   │
│   │  @Bot    │◀───│  /webhook  │◀───│  (bot)   │    │  Chat API        │   │
│   └──────────┘    └────────────┘    └──────────┘    └──────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 数据流说明

| 流程 | 路径 | 说明 |
|------|------|------|
| 自动调查 | Alarm → EventBridge → Lambda-A → DevOps Agent | 告警自动触发调查 |
| 自动通知 | Agent 完成 → EventBridge → Lambda-B → 飞书群 | 调查结果自动推送 |
| 交互对话 | 飞书 @Bot → API Gateway → Lambda-C ↔ Agent Chat API | 实时问答排查 |

---

## 前置条件

| 条件 | 说明 | 验证命令 |
|------|------|----------|
| EKS 环境已部署 | 已运行 `./terraform/deploy.sh` | `kubectl get pods -A` |
| DevOps Agent Space 已创建 | deploy.sh 会自动创建 | `aws devops-agent list-agent-spaces --region us-east-1` |
| 飞书企业账号 | 需要管理员权限创建自建应用 | 登录 https://open.feishu.cn |
| AWS CLI 已配置 | 有权限创建 Lambda、IAM、EventBridge、API Gateway | `aws sts get-caller-identity` |

---

## Step 1: 创建飞书应用

1. 访问 [飞书开放平台](https://open.feishu.cn/app)
2. 点击 **创建企业自建应用**
3. 填写：
   - **应用名称**：`DevOps Agent Bot`（或你喜欢的名字）
   - **应用描述**：`AWS DevOps Agent 运维助手，支持自动调查通知和交互式排查`
4. 点击 **确定创建**

### 记录凭证

进入应用后：

1. 左侧菜单 → **凭证与基础信息**
2. 记录以下两个值（后续部署需要）：

| 字段 | 说明 | 示例 |
|------|------|------|
| **App ID** | 应用唯一标识 | `cli_a5xxxxxxxxxxxx` |
| **App Secret** | 应用密钥（不要泄露） | `xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx` |

---

## Step 2: 配置飞书应用能力

在飞书开放平台你的应用中，完成以下 3 项配置：

### 2.1 开启机器人

1. 左侧菜单 → **应用功能** → **机器人**
2. 点击 **开启**
3. 填写 Bot 名称（群内 @ 时显示的名字，如 `DevOps Agent`）

### 2.2 添加权限

1. 左侧菜单 → **权限管理**
2. 搜索并 **开通** 以下权限：

| 权限名称 | 权限标识 | 用途 |
|----------|----------|------|
| 获取与发送单聊、群组消息 | `im:message` | 接收用户发给 Bot 的消息 |
| 以应用的身份发消息 | `im:message:send_as_bot` | Bot 回复消息和推送通知 |
| 获取群组信息 | `im:chat:readonly` | 获取群 Chat ID |

### 2.3 配置事件订阅

1. 左侧菜单 → **事件订阅**
2. 订阅方式选择 **长连接** 或 **使用事件订阅 2.0 推送请求**
3. 添加事件：搜索 `im.message.receive_v1`（接收消息 v2.0）→ 申请开通
4. **请求地址**：暂时留空（Step 7 部署完成后再回来填）

> 可选：记录页面上的 **Verification Token** 和 **Encrypt Key**，部署时可以设为环境变量增强安全性。

---

## Step 3: 发布飞书应用

1. 左侧菜单 → **版本管理与发布**
2. 点击 **创建版本**
3. 填写版本号和更新说明
4. 点击 **提交审核**
5. 等待企业管理员审核通过

> **重要**：应用未发布审核通过前，Bot 无法在群内接收和回复消息。如果你是管理员，可以在管理后台直接审核通过。

---

## Step 4: 获取飞书群 Chat ID

### 4.1 将 Bot 添加到群

1. 打开目标飞书群（或新建一个群，如 **"DevOps 告警群"**）
2. 点击群右上角 **设置**（⚙️ 图标）
3. **群机器人** → **添加机器人** → 搜索你的 Bot 名称 → 添加

### 4.2 通过 API 获取 Chat ID

```bash
# 替换为你的 App ID 和 App Secret
FEISHU_APP_ID="cli_a5xxxxxxxxxxxx"
FEISHU_APP_SECRET="你的App Secret"

# 获取 tenant_access_token
TOKEN=$(curl -s -X POST 'https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal' \
  -H 'Content-Type: application/json' \
  -d "{\"app_id\":\"${FEISHU_APP_ID}\",\"app_secret\":\"${FEISHU_APP_SECRET}\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['tenant_access_token'])")

echo "Token acquired: ${TOKEN:0:10}..."

# 列出 Bot 所在的群
curl -s -X GET 'https://open.feishu.cn/open-apis/im/v1/chats?page_size=20' \
  -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys, json
data = json.load(sys.stdin)
items = data.get('data', {}).get('items', [])
if not items:
    print('  (未找到群组 - 请确认 Bot 已添加到群中)')
for item in items:
    print(f\"  {item['name']:30s} → chat_id: {item['chat_id']}\")
"
```

输出示例：
```
  DevOps 告警群                    → chat_id: oc_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
  测试群                           → chat_id: oc_yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy
```

记录目标群的 `chat_id` 值。

### 4.3 替代方式

如果 API 调用不便，也可以：
1. 先完成 Step 6-7 部署
2. 在群里 @Bot 发任意消息
3. 查看 Lambda 日志中打印的 `chat_id`：
   ```bash
   aws logs tail /aws/lambda/devops-agent-feishu-bot --since 5m
   ```

---

## Step 5: 获取 DevOps Agent Space ID

`deploy.sh` 已经自动创建了 Agent Space。获取 Space ID：

### 方式 A: 从 deploy 输出获取

部署完成时终端会输出：
```
🤖 DevOps Agent Space: f95eb69d-46e2-48c9-875f-07536fd3b4b2
```

### 方式 B: 通过 CLI 查询

```bash
aws devops-agent list-agent-spaces --region us-east-1 \
  --query "agentSpaces[?contains(name,'retail-store')].{name:name,id:agentSpaceId}" \
  --output table
```

输出示例：
```
--------------------------------------------------------------
|                       ListAgentSpaces                       |
+-------------------------------+----------------------------+
|             name              |             id             |
+-------------------------------+----------------------------+
|  retail-store-workshop        |  f95eb69d-46e2-48c9-875f-  |
|                               |  07536fd3b4b2              |
+-------------------------------+----------------------------+
```

### 方式 C: 通过控制台

1. 打开 [DevOps Agent Console](https://console.aws.amazon.com/devops-agent/home?region=us-east-1)
2. 点击你的 Agent Space
3. URL 中或概览面板可见 Space ID

---

## Step 6: 部署飞书集成

### 6.1 设置环境变量

```bash
# 必需：4 个变量
export DEVOPS_AGENT_SPACE_ID="<Step 5 获取的 Space ID>"
export FEISHU_APP_ID="<Step 1 记录的 App ID>"
export FEISHU_APP_SECRET="<Step 1 记录的 App Secret>"
export FEISHU_CHAT_ID="<Step 4 获取的 Chat ID>"

# 可选：安全增强
export FEISHU_VERIFICATION_TOKEN="<飞书事件订阅页面的 Verification Token>"
export FEISHU_ENCRYPT_KEY="<飞书事件订阅页面的 Encrypt Key>"

# 可选：自定义区域和集群名
export AWS_REGION="us-east-1"
export CLUSTER_NAME="retail-store"
```

### 6.2 验证变量

```bash
echo "================================"
echo "DEVOPS_AGENT_SPACE_ID = $DEVOPS_AGENT_SPACE_ID"
echo "FEISHU_APP_ID         = $FEISHU_APP_ID"
echo "FEISHU_APP_SECRET     = ${FEISHU_APP_SECRET:0:8}********"
echo "FEISHU_CHAT_ID        = $FEISHU_CHAT_ID"
echo "================================"
```

确认所有变量非空后继续。

### 6.3 执行部署

```bash
cd feishu-integration
chmod +x deploy.sh
./deploy.sh
```

### 6.4 部署输出

部署成功后会看到：

```
╔═══════════════════════════════════════════════════════════════╗
║        🎉 Feishu Integration Deployed Successfully!           ║
╚═══════════════════════════════════════════════════════════════╝

Components deployed:
  • Lambda-A: devops-agent-trigger-investigation (CloudWatch → Agent)
  • Lambda-B: devops-agent-notify-feishu (Agent → Feishu notification)
  • Lambda-C: devops-agent-feishu-bot (Feishu ↔ Agent Chat)
  • EventBridge Rule 1: CloudWatch Alarm → Lambda-A
  • EventBridge Rule 2: Investigation Completed → Lambda-B
  • API Gateway: Feishu bot webhook endpoint

Webhook URL: https://xxxxxxxx.execute-api.us-east-1.amazonaws.com/webhook
```

**记录 Webhook URL**，下一步需要填入飞书。

---

## Step 7: 配置飞书 Webhook URL

1. 回到 [飞书开放平台](https://open.feishu.cn/app) → 你的应用
2. 左侧菜单 → **事件订阅**
3. 在 **请求地址** 中填入 Step 6 输出的 Webhook URL：
   ```
   https://xxxxxxxx.execute-api.us-east-1.amazonaws.com/webhook
   ```
4. 点击 **保存**

飞书会立即发送一个 `challenge` 验证请求到该 URL。Lambda-C 会自动响应验证。

**验证结果：**
- ✅ 绿色对勾 = 配置成功
- ❌ 红色叉号 = 配置失败（参考[故障排查](#问题飞书验证-url-失败)）

---

## Step 8: 验证集成

### 验证 1: Bot 对话功能

在飞书群中 @Bot 发送消息：

```
@DevOps Agent Bot 你好，查看一下 EKS 集群的健康状态
```

**预期结果**：Bot 在几秒到几十秒内回复 EKS 集群的相关信息。

### 验证 2: 自动调查 + 通知

```bash
# 注入故障（从项目根目录执行）
cd fault-injection
./inject-catalog-latency.sh

# 观察流程：
# 1. CloudWatch Alarm 触发（约 5-10 分钟后）
# 2. Lambda-A 自动创建调查任务
# 3. DevOps Agent 自主调查（5-15 分钟）
# 4. Lambda-B 获取结果并推送到飞书群

# 实时查看 Lambda 日志
aws logs tail /aws/lambda/devops-agent-trigger-investigation --follow --since 5m
```

**预期结果**：飞书群收到一条调查报告，包含根因分析和修复建议。

### 验证 3: 手动触发测试（快速验证）

如果不想等 CloudWatch 告警，可以手动调用 Lambda-A：

```bash
aws lambda invoke \
  --function-name devops-agent-trigger-investigation \
  --cli-binary-format raw-in-base64-out \
  --payload '{
    "detail": {
      "alarmName": "retail-store-catalog-cpu-high",
      "state": {"value": "ALARM", "reason": "Threshold Crossed: CPU > 80%"},
      "configuration": {
        "metrics": [{
          "metricStat": {
            "metric": {
              "dimensions": {"ClusterName": "retail-store"}
            }
          }
        }]
      }
    }
  }' \
  /tmp/lambda-a-output.json && cat /tmp/lambda-a-output.json
```

输出应包含 `taskId` 和 `executionId`，表示调查已创建。

---

## 使用方式

### 交互式对话示例

| 在飞书群中发送 | 说明 |
|---------------|------|
| `@Bot What EC2 instances are running?` | 查询运行实例 |
| `@Bot Why is the catalog service slow?` | 排查性能问题 |
| `@Bot Check EKS pod health in catalog namespace` | 检查 Pod 状态 |
| `@Bot Are there any OOMKills or pod restarts?` | 检查资源问题 |
| `@Bot Show me recent errors in orders service logs` | 查看错误日志 |
| `@Bot 分析一下 carts 服务的 DynamoDB 性能` | 中文提问也支持 |

### 特殊命令

| 命令 | 说明 |
|------|------|
| `/reset` 或 `重置` | 重置对话会话，清除上下文，开始新的调查 |
| `/new` 或 `新对话` | 同上 |

### 多轮对话

Bot 支持多轮对话，同一会话内保持上下文：

```
用户: @Bot 列出 catalog namespace 的所有 pods
Bot:  catalog namespace 中有 2 个 pods...

用户: @Bot 哪个 pod 的 CPU 使用率最高?
Bot:  基于上面的 pods，catalog-xxx 的 CPU 使用率达到 95%...

用户: @Bot 分析一下为什么这个 pod CPU 这么高
Bot:  深入分析发现该 pod 有一个 stress sidecar 容器...
```

---

## 故障排查

### 问题：飞书验证 URL 失败

```bash
# 测试 API Gateway 是否正常响应 challenge
curl -X POST 'https://<api-id>.execute-api.<region>.amazonaws.com/webhook' \
  -H 'Content-Type: application/json' \
  -d '{"challenge": "test-12345"}'

# 期望返回: {"challenge": "test-12345"}
```

**如果无响应，检查：**

```bash
# API Gateway 是否存在
aws apigatewayv2 get-apis --query "Items[?Name=='devops-agent-feishu-bot-api']"

# Lambda 是否有调用权限
aws lambda get-policy --function-name devops-agent-feishu-bot

# Lambda 是否有错误
aws logs tail /aws/lambda/devops-agent-feishu-bot --since 10m
```

### 问题：Bot 不回复消息

```bash
# 查看 Lambda-C 日志
aws logs tail /aws/lambda/devops-agent-feishu-bot --follow
```

**常见原因及解决：**

| 原因 | 解决方式 |
|------|----------|
| 应用未发布 | 飞书开放平台 → 版本管理 → 提交审核 |
| 未订阅消息事件 | 事件订阅 → 添加 `im.message.receive_v1` |
| Bot 未在群内 | 群设置 → 群机器人 → 添加 |
| 缺少发送权限 | 权限管理 → 开通 `im:message:send_as_bot` |
| Webhook URL 错误 | 确认 URL 和 Step 6 输出一致 |
| Lambda 超时 | DevOps Agent 响应慢，Lambda 超时已设 120s |

### 问题：调查结果未推送到飞书

```bash
# 检查 EventBridge 规则
aws events describe-rule --name "devops-agent-investigation-completed"

# 检查 Lambda-B 最近执行
aws logs tail /aws/lambda/devops-agent-notify-feishu --since 2h

# 手动触发 Lambda-B 测试飞书推送
aws lambda invoke \
  --function-name devops-agent-notify-feishu \
  --cli-binary-format raw-in-base64-out \
  --payload '{
    "detail": {
      "metadata": {
        "agent_space_id": "'"$DEVOPS_AGENT_SPACE_ID"'",
        "task_id": "test-task-001",
        "execution_id": "test-exec-001"
      },
      "data": {
        "priority": "HIGH",
        "status": "COMPLETED"
      }
    }
  }' \
  /tmp/lambda-b-output.json && cat /tmp/lambda-b-output.json
```

**常见原因：**

| 原因 | 解决方式 |
|------|----------|
| Space ID 错误 | 确认 `DEVOPS_AGENT_SPACE_ID` 正确 |
| 飞书 Token 获取失败 | 确认 `FEISHU_APP_ID` 和 `FEISHU_APP_SECRET` 正确 |
| Chat ID 错误 | 确认 Bot 在目标群中，重新获取 Chat ID |
| EventBridge 未匹配 | 确认事件 source 是 `aws.aidevops`（不是 `aws.devops-agent`） |

### 问题：DevOps Agent API 调用失败

```bash
# 确认 boto3 Layer 是否正确（Lambda 内置版本不含 devops-agent client）
aws lambda get-function --function-name devops-agent-feishu-bot \
  --query "Configuration.Layers"

# 确认 IAM 权限
aws iam get-role-policy \
  --role-name DevOpsAgentFeishuLambdaRole \
  --policy-name DevOpsAgentAccess

# 测试 DevOps Agent API 是否可用
aws devops-agent list-agent-spaces --region us-east-1
```

---

## 环境变量参考

### 必需变量（4 个）

| 变量 | 说明 | 格式 | 获取方式 |
|------|------|------|----------|
| `DEVOPS_AGENT_SPACE_ID` | Agent Space ID | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` | deploy.sh 输出 或 CLI 查询 |
| `FEISHU_APP_ID` | 飞书应用 App ID | `cli_aXXXXXXXXXXXXXX` | 飞书开放平台 → 凭证信息 |
| `FEISHU_APP_SECRET` | 飞书应用密钥 | 32 位字符串 | 飞书开放平台 → 凭证信息 |
| `FEISHU_CHAT_ID` | 飞书群 Chat ID | `oc_XXXXXXXXXXXXXXXX` | API 调用获取 |

### 可选变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `AWS_REGION` | AWS 区域 | `us-east-1` |
| `CLUSTER_NAME` | EKS 集群名称 | `retail-store` |
| `FEISHU_VERIFICATION_TOKEN` | 飞书事件验证 Token | (空) |
| `FEISHU_ENCRYPT_KEY` | 飞书事件加密密钥 | (空) |

---

## 安全建议

| 建议 | 说明 |
|------|------|
| 不要硬编码 Secret | 生产环境使用 AWS Secrets Manager 或 Parameter Store |
| 限制 API Gateway 访问 | 配置 WAF 或 IP 白名单，仅允许飞书服务器 IP 段 |
| 最小化 IAM 权限 | 将 `Resource: "*"` 替换为具体 Agent Space ARN |
| 启用飞书加密 | 配置 Encrypt Key 加密事件消息体 |
| 审计日志 | 所有 DevOps Agent API 调用自动记录在 CloudTrail |
| 定期轮换 Secret | 定期更新飞书 App Secret 和相关配置 |

---

## 清理

### 仅清理飞书集成

```bash
cd feishu-integration
./destroy.sh
```

清理内容：
- 3 个 Lambda 函数
- 2 条 EventBridge 规则
- 1 个 API Gateway
- 1 个 Lambda Layer
- 1 个 IAM Role

### 清理全部环境（含 EKS）

```bash
# 先清理飞书集成
cd feishu-integration
./destroy.sh

# 再销毁 EKS 环境
cd ../terraform
./destroy.sh
```

### 飞书侧清理

1. 飞书开放平台 → 你的应用 → **停用** 或 **删除**
2. 从飞书群中 **移除** Bot

---

## 完整流程速查

```bash
# === 一次性配置（约 10 分钟，不含飞书审核） ===

# 1. 飞书开放平台创建应用 → 获取 App ID + Secret
# 2. 开启机器人、配置权限、添加事件订阅
# 3. 提交审核发布
# 4. Bot 添加到群 → 获取 Chat ID
# 5. 设置环境变量
export DEVOPS_AGENT_SPACE_ID="..."
export FEISHU_APP_ID="..."
export FEISHU_APP_SECRET="..."
export FEISHU_CHAT_ID="..."

# 6. 部署
cd feishu-integration && ./deploy.sh

# 7. 将输出的 Webhook URL 填入飞书事件订阅
# 8. 在群里 @Bot 测试

# === 日常使用 ===

# 注入故障 → 等待自动调查 → 飞书收通知
cd fault-injection && ./inject-catalog-latency.sh

# 群内交互排查
# @Bot 为什么 catalog 服务响应慢？

# 回滚故障
./rollback-catalog.sh
```
