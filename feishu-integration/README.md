# Feishu (飞书) Integration for DevOps Agent Workshop

将 AWS DevOps Agent 与飞书集成，实现：

1. **交互式对话** — 在飞书群 @Bot 提问，通过 Chat API 实时排查
2. **调查结果自动通知** — Investigation 完成后自动推送调查报告到飞书群
3. **全自动闭环**（Lab 0） — 故障注入 → CloudWatch Alarm → 自动创建调查 → 调查完成 → 飞书通知

## 架构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     全自动调查 (Lab 0 启用后)                                 │
│                                                                             │
│  Fault Injection → CloudWatch Alarm → EventBridge → Lambda (auto_investigator)
│                                                       │                     │
│                                                       ▼                     │
│                                               DevOps Agent                  │
│                                            (自主调查 10-20min)               │
│                                                       │                     │
│                                                       ▼                     │
│  飞书群通知 ← Lambda (investigation_notifier) ← EventBridge (aws.aidevops)   │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                     交互式对话 (WebSocket)                                    │
│                                                                             │
│  飞书用户 @Bot ←→ (wss://feishu.cn) ←→ EKS Pod (feishu-bot) ←→ Chat API    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 组件

| 组件 | 部署方式 | 功能 |
|------|----------|------|
| `k8s/bot.py` | EKS Pod (WebSocket) | 飞书交互对话 ↔ DevOps Agent Chat API |
| `lambda/investigation_notifier/` | Lambda + EventBridge | 调查完成 → 飞书通知 |
| `lambda/auto_investigator/` | Lambda + CloudWatch Alarm | 告警 → 自动创建调查 |

## 前置条件

- EKS 环境已部署 (`../terraform/deploy.sh`)
- DevOps Agent Space 已创建（deploy.sh 自动完成）
- 飞书企业自建应用（Bot）

## 飞书应用配置

1. 访问 [飞书开放平台](https://open.feishu.cn/app) → 创建企业自建应用
2. **应用功能** → **机器人** → 开启
3. **权限管理** → 开通：
   - `im:message`
   - `im:message:send_as_bot`
   - `im:chat:readonly`
4. **事件订阅** → 选择 **使用长连接接收事件** → 添加 `im.message.receive_v1`
5. **版本管理** → 发布审核
6. 将 Bot 添加到飞书群

> **重要**：必须选择"长连接"模式（不是"发送到开发者服务器"）。中国版飞书无法访问境外 API Gateway。

## 部署

### 1. 交互式 Bot（WebSocket）

```bash
export DEVOPS_AGENT_SPACE_ID="<your-agent-space-id>"
export FEISHU_APP_ID="<your-feishu-app-id>"
export FEISHU_APP_SECRET="<your-feishu-app-secret>"
export FEISHU_CHAT_ID="<your-feishu-chat-id>"

./deploy-k8s-bot.sh
```

### 2. 调查完成通知（Investigation → 飞书）

```bash
./deploy-notifier.sh
```

### 3. 全自动闭环（Lab 0）

```bash
cd ../fault-injection
./lab0-enable-auto-investigation.sh
```

## 使用方式

### 交互对话

在飞书群 @Bot：

| 示例 | 说明 |
|------|------|
| `@Bot 查看 EKS 集群健康状态` | 集群概览 |
| `@Bot catalog 服务 CPU 异常，请分析根因` | 排查问题 |
| `@Bot 有没有 pod 重启或 OOMKill?` | 资源检查 |
| `/reset` | 重置对话上下文 |

### 全自动调查（Lab 0 启用后）

```bash
cd fault-injection
./inject-catalog-latency.sh
# 无需任何操作
# → CloudWatch Alarm 自动触发
# → DevOps Agent 自动调查
# → 飞书群收到完整调查报告
```

## 日志

```bash
# Bot 日志
kubectl logs -f -n feishu-bot -l app=feishu-bot

# 调查通知 Lambda
aws logs tail /aws/lambda/devops-agent-investigation-notifier --follow --region us-east-1

# 自动调查 Lambda
aws logs tail /aws/lambda/devops-agent-auto-investigator --follow --region us-east-1
```

## 清理

```bash
# 关闭自动调查
cd ../fault-injection && ./lab0-disable-auto-investigation.sh

# 删除 Bot
kubectl delete namespace feishu-bot
aws iam delete-role-policy --role-name FeishuBotPodRole-retail-store --policy-name DevOpsAgentChat
aws iam delete-role --role-name FeishuBotPodRole-retail-store

# 删除通知 Lambda
aws lambda delete-function --function-name devops-agent-investigation-notifier --region us-east-1
aws events remove-targets --rule devops-agent-investigation-completed --ids investigation-notifier --region us-east-1
aws events delete-rule --name devops-agent-investigation-completed --region us-east-1
aws iam delete-role-policy --role-name InvestigationNotifierLambdaRole --policy-name DevOpsAgentRead
aws iam detach-role-policy --role-name InvestigationNotifierLambdaRole --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role --role-name InvestigationNotifierLambdaRole
```

## 详细配置指南

参见 [docs/setup-guide.md](docs/setup-guide.md)
