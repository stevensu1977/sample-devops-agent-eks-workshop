# Feishu (飞书) Integration for DevOps Agent Workshop

将 AWS DevOps Agent 集成到飞书，实现双向交互：

1. **自动通知** — CloudWatch 告警触发 → DevOps Agent 自主调查 → 调查结果自动推送到飞书群
2. **交互式对话** — 在飞书群内 @Bot 提问，直接与 DevOps Agent Chat API 实时对话排查问题

## 架构

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        自动调查流程 (Event-Driven)                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  EKS Fault  →  CloudWatch Alarm  →  EventBridge  →  Lambda-A           │
│                                                       │                 │
│                                                       ▼                 │
│                                               DevOps Agent              │
│                                            (自主调查 5-15min)            │
│                                                       │                 │
│                                                       ▼                 │
│  飞书群通知  ←  Lambda-B  ←  EventBridge  ←  Investigation Completed    │
│                                                                         │
├─────────────────────────────────────────────────────────────────────────┤
│                        交互式对话 (Chat API)                              │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  飞书用户 @Bot  →  API Gateway  →  Lambda-C  →  DevOps Agent Chat API   │
│       ↑                                              │                  │
│       └──────────────────────────────────────────────┘                  │
│                         回复消息                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

## 前置条件

- 已部署 EKS Workshop 环境 (`../terraform/deploy.sh`)
- 已创建 DevOps Agent Space（参考主 README）
- 飞书开发者账号，并创建了企业自建应用（Bot）

## 飞书应用配置

### 1. 创建飞书应用

1. 访问 [飞书开放平台](https://open.feishu.cn/app)
2. 创建企业自建应用
3. 记录 `App ID` 和 `App Secret`

### 2. 配置 Bot 能力

1. 应用功能 → 机器人 → 开启
2. 事件订阅：
   - 添加事件：`im.message.receive_v1`（接收消息）
   - 请求地址：部署后填入 API Gateway URL
3. 权限管理 → 添加权限：
   - `im:message:send_as_bot`（发送消息）
   - `im:message`（获取消息）
   - `im:chat:readonly`（获取群信息）

### 3. 获取群 Chat ID

将 Bot 添加到目标群后，通过 API 获取 Chat ID：
```bash
curl -X GET 'https://open.feishu.cn/open-apis/im/v1/chats' \
  -H 'Authorization: Bearer <tenant_access_token>'
```

## 部署

### 环境变量

```bash
export DEVOPS_AGENT_SPACE_ID="<your-agent-space-id>"
export FEISHU_APP_ID="<your-feishu-app-id>"
export FEISHU_APP_SECRET="<your-feishu-app-secret>"
export FEISHU_CHAT_ID="<your-feishu-group-chat-id>"

# Optional
export AWS_REGION="us-east-1"
export CLUSTER_NAME="retail-store"
export FEISHU_VERIFICATION_TOKEN="<event-verification-token>"
export FEISHU_ENCRYPT_KEY="<event-encrypt-key>"
```

### 一键部署

```bash
chmod +x deploy.sh
./deploy.sh
```

部署完成后，脚本会输出 API Gateway webhook URL。将此 URL 配置到飞书应用的事件订阅请求地址中。

## 使用方式

### 自动调查通知

注入故障后，当 CloudWatch 告警触发时，整个流程自动执行：

```bash
cd ../fault-injection
./inject-catalog-latency.sh
# 等待 CloudWatch 告警触发 → Agent 调查 → 飞书群收到调查报告
```

### 交互式对话

在飞书群中 @Bot 发送消息：

| 示例提问 | 说明 |
|---------|------|
| `@Bot What EC2 instances are running?` | 查询运行中的实例 |
| `@Bot Why is the catalog service slow?` | 排查服务性能问题 |
| `@Bot Check EKS pod health in catalog namespace` | 检查 Pod 状态 |
| `@Bot Are there any OOMKills or pod restarts?` | 检查资源问题 |
| `@Bot Show me recent errors in orders service` | 查看服务错误日志 |

### 特殊命令

| 命令 | 说明 |
|------|------|
| `/reset` 或 `重置` | 重置当前对话会话，开始新的调查上下文 |
| `/new` 或 `新对话` | 同上 |

## 组件说明

| 组件 | 功能 |
|------|------|
| `lambda/trigger_investigation/` | Lambda-A: CloudWatch Alarm → 创建 DevOps Agent 调查任务 |
| `lambda/notify_feishu/` | Lambda-B: 调查完成 → 获取摘要 → 发送飞书通知 |
| `lambda/feishu_bot/` | Lambda-C: 飞书消息 → DevOps Agent Chat API → 回复飞书 |
| `iam/` | IAM 角色信任策略和权限策略 |
| `deploy.sh` | 一键部署脚本 |
| `destroy.sh` | 清理脚本 |

## 注意事项

- Lambda 运行时内置 boto3 **不包含** `devops-agent` client，必须通过 Layer 提供最新版本
- DevOps Agent IAM action 前缀是 `aidevops`（不是 `devops-agent`）
- EventBridge source 是 `aws.aidevops`
- Feishu Bot Lambda 超时设为 120s，因为 DevOps Agent Chat API 调用可能需要较长时间
- 会话状态存储在 Lambda 实例内存中；生产环境建议改用 DynamoDB 持久化

## 清理

```bash
./destroy.sh
```

## 故障排查

```bash
# 查看 Lambda-A 日志
aws logs tail /aws/lambda/devops-agent-trigger-investigation --follow

# 查看 Lambda-B 日志
aws logs tail /aws/lambda/devops-agent-notify-feishu --follow

# 查看 Bot Lambda 日志
aws logs tail /aws/lambda/devops-agent-feishu-bot --follow

# 测试 API Gateway endpoint
curl -X POST https://<api-id>.execute-api.<region>.amazonaws.com/webhook \
  -H "Content-Type: application/json" \
  -d '{"challenge": "test-verification"}'
```
