# Feishu (飞书) Integration for DevOps Agent Workshop

将 AWS DevOps Agent 集成到飞书，通过 WebSocket 长连接实现双向交互式对话排查。

## 架构

```
┌──────────┐    WebSocket (outbound)     ┌──────────────────┐
│ 飞书用户 │◀───────────────────────────▶│  EKS Pod         │
│  @Bot    │     (wss://feishu.cn)       │  (feishu-bot)    │
└──────────┘                             └────────┬─────────┘
                                                  │
                                                  ▼
                                         ┌──────────────────┐
                                         │  DevOps Agent    │
                                         │  Chat API        │
                                         └──────────────────┘
```

**关键设计**：Pod 主动连接飞书 WebSocket（出站连接），不需要公网入口。
解决了 feishu.cn（中国版）无法访问境外 AWS API Gateway 的跨境网络问题。

## 前置条件

- EKS 环境已部署 (`../terraform/deploy.sh`)
- DevOps Agent Space 已创建（deploy.sh 自动完成）
- 飞书企业自建应用（Bot），事件订阅方式选择 **长连接**

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

## 部署

```bash
export DEVOPS_AGENT_SPACE_ID="<your-agent-space-id>"
export FEISHU_APP_ID="<your-feishu-app-id>"
export FEISHU_APP_SECRET="<your-feishu-app-secret>"
export FEISHU_CHAT_ID="<your-feishu-chat-id>"

cd feishu-integration
./deploy-k8s-bot.sh
```

部署内容：
- 创建 `feishu-bot` namespace
- IRSA IAM Role（Pod 权限调用 DevOps Agent API）
- Deployment: python:3.12-slim + lark-oapi SDK + boto3

## 使用方式

在飞书群 @Bot 发消息：

| 示例 | 说明 |
|------|------|
| `@Bot 查看 EKS 集群健康状态` | 检查集群 |
| `@Bot Why is the catalog service slow?` | 排查性能 |
| `@Bot 有没有 pod 重启或 OOMKill?` | 检查资源 |
| `/reset` 或 `重置` | 重置对话上下文 |

支持多轮对话，同一会话保持上下文。

## 查看日志

```bash
kubectl logs -f -n feishu-bot -l app=feishu-bot
```

## 清理

```bash
kubectl delete namespace feishu-bot
aws iam delete-role-policy --role-name FeishuBotPodRole-retail-store --policy-name DevOpsAgentChat
aws iam delete-role --role-name FeishuBotPodRole-retail-store
```
