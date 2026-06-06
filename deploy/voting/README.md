# OpenFang 投票集群方案设计

> 目标：在 OpenFang manifest-pipeline Hand 基础上，实现多 Agent 并发处理 + 投票表决，提高准确率
> 原则：零侵入 OpenFang 代码，纯配置 + 外部组件

## 一、方案原理

### 1.1 核心思路

在 OpenFang 和外部处理 Agent 之间，插入一层**投票网关**。

投票网关对 OpenFang 来说就是一个普通 A2A 外部 Agent；对内部则并发调用多个处理 Agent，收集结果后投票表决，返回最终答案。

```
┌─────────────────────────────────────────────────────────────┐
│  用户 (浏览器 Dashboard)                                      │
│  上传文件 → manifest-pipeline Hand Agent                     │
└──────────────┬──────────────────────────────────────────────┘
               │
               │ OpenFang 内部（零改动）
               │
┌──────────────▼──────────────────────────────────────────────┐
│  manifest-pipeline Hand Agent (现有 v12)                     │
│                                                             │
│  1. [FILE_ATTACHMENT] 接收文件路径                           │
│  2. MCP mcp_obs_s3_s3_upload → 上传到华为云 OBS              │
│  3. a2a_send({ agent_name: "manifest-agent" }) ─────────────┼──→ 指向投票网关
│  4. 收到结果 → 返回给用户                                    │
└─────────────────────────────────────────────────────────────┘

                           │ A2A 协议 (JSON-RPC)
                           ▼

┌─────────────────────────────────────────────────────────────┐
│  投票网关 (voting-gateway, Python FastAPI)                    │
│                                                             │
│  对外：实现 A2A 协议 (/.well-known/agent.json + /a2a)        │
│  对内：并发 × N → 收集结果 → 投票 → 返回                     │
│                                                             │
│  ┌───────────────────────────────────────────────────┐      │
│  │  收到 a2a_send 请求                                │      │
│  │       │                                           │      │
│  │       ├── 解析出 S3 URL + 任务描述                  │      │
│  │       │                                           │      │
│  │       ├── asyncio.gather(×N) 并发请求              │      │
│  │       │   ├── HTTP → worker-1 (外部Agent)          │      │
│  │       │   ├── HTTP → worker-2 (外部Agent)          │      │
│  │       │   ├── ...                                  │      │
│  │       │   └── HTTP → worker-N (外部Agent)          │      │
│  │       │                                           │      │
│  │       ├── 收集成功/失败结果                         │      │
│  │       │                                           │      │
│  │       ├── 投票策略：                               │      │
│  │       │   • majority: 多数投票                     │      │
│  │       │   • llm_arbitrate: LLM 仲裁（推荐）        │      │
│  │       │   • exact_match: 精确匹配计数              │      │
│  │       │                                           │      │
│  │       └── 返回 A2A completed + 投票结果             │      │
│  └───────────────────────────────────────────────────┘      │
└──────────────┬──────────────┬──────────────┬────────────────┘
               │              │              │
          ┌────▼───┐    ┌────▼───┐    ┌─────▼──┐
          │Worker 1│    │Worker 2│    │Worker N│
          │(你的    │    │(你的    │    │(你的    │
          │DeepAgent│   │DeepAgent│   │DeepAgent│
          └────────┘    └────────┘    └─────────┘
```

### 1.2 为什么这样做

| 问题 | 方案选择 |
|------|----------|
| OpenFang agent 工具调用是串行的 | 并发不在 OpenFang 内部做 |
| 单 Agent 有 Mutex 锁 | 投票网关不是 OpenFang Agent |
| OpenFang 没有投票机制 | 投票在网关内实现 |
| FanOut 需要创建 N 个 Agent | 网关内并发，OpenFang 只需 1 个 Agent |
| 不想改 OpenFang 代码 | 只改 config.toml 里 1 行 URL |

### 1.3 数据流

```
1. 用户在 Dashboard 上传 report.xlsx
2. OpenFang 保存到 /tmp/openfang_uploads/{uuid}
3. Hand Agent 收到 [FILE_ATTACHMENT] path="/tmp/openfang_uploads/xxx"
4. Hand Agent 调用 MCP mcp_obs_s3_s3_upload → 得到 S3 URL
5. Hand Agent 调用 a2a_send → 发给投票网关
   请求: { "message": "Process file at S3 URL: https://obs.xxx/uploads/report.xlsx" }
6. 投票网关收到后：
   a. 解析出 S3 URL
   b. 并发 ×10 调用外部 Agent
   c. 收集 10 个结果
   d. 投票表决
   e. 返回最终结果
7. Hand Agent 收到投票结果，返回给用户
```

### 1.4 投票策略

| 策略 | 原理 | 适用场景 | 配置 |
|------|------|----------|------|
| `exact_match` | 精确字符串匹配，计数最多者胜出 | 结构化输出（JSON、数字） | `VOTE_STRATEGY=exact_match` |
| `majority` | 精确匹配 + 要求超过半数 | 分类/选择题 | `VOTE_STRATEGY=majority` |
| `llm_arbitrate` | 用 LLM 分析多个结果，综合判断 | 开放式问答、复杂推理（推荐） | `VOTE_STRATEGY=llm_arbitrate` |

### 1.5 容错设计

- 单个 Worker 超时/失败 → 不影响其他 Worker，降级为 N-1 投票
- 全部 Worker 失败 → 返回错误信息给 OpenFang
- 最少成功数阈值（`MIN_SUCCESS`）：低于此数则认为投票无效

---

## 二、文件结构

```
deploy/voting/
├── README.md                    # 本文件
├── docker-compose.yml           # 完整部署编排
├── .env.example                 # 环境变量模板
├── config.toml                  # OpenFang 配置（基于 manifest config 修改）
├── hands/
│   └── manifest-pipeline/       # 从现有 deploy/manifest/hands 复制，不改
│       ├── HAND.toml
│       └── SKILL.md
├── voting-gateway/              # 投票网关服务
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── server.py                # 主服务（A2A 协议 + 投票逻辑）
│   └── config.py                # 配置读取
├── mock-worker/                 # Mock 外部 Agent（用于测试验证）
│   ├── Dockerfile
│   ├── requirements.txt
│   └── server.py
├── scripts/
│   ├── start.sh                 # 一键启动
│   ├── stop.sh                  # 一键停止
│   └── verify.sh                # 自动化验证脚本
└── CHANGELOG.md
```

---

## 三、部署

### 3.1 环境要求

- Docker + Docker Compose
- OpenFang 离线镜像：`openfang:0.6.4-offline-manifest-v12`
- MCP OBS S3 镜像：`mcp-obs-s3:1.2.0`
- 投票网关镜像：本地构建
- Mock Worker 镜像（测试用）：本地构建

### 3.2 配置

```bash
cd deploy/voting
cp .env.example .env
# 编辑 .env，填入：
#   OPENAI_API_KEY=xxx
#   OBS_ACCESS_KEY_ID=xxx
#   OBS_SECRET_ACCESS_KEY=xxx
#   OBS_ENDPOINT=xxx
#   OBS_BUCKET=xxx
```

### 3.3 启动

```bash
# 方式一：一键脚本
./scripts/start.sh

# 方式二：手动
docker compose up -d --build
```

### 3.4 验证

```bash
# 自动化验证（包含所有检查项）
./scripts/verify.sh

# 手动逐步验证：
# 1. 健康检查
curl http://localhost:4200/api/health

# 2. 检查投票网关 A2A Agent Card
curl http://localhost:9200/.well-known/agent.json

# 3. 直接测试投票网关（不发 OpenFang）
curl -X POST http://localhost:9200/a2a \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tasks/send",
    "params": {
      "message": {
        "role": "user",
        "parts": [{"type": "text", "text": "Process file at S3 URL: https://test.obs.xxx/test.xlsx"}]
      }
    }
  }'

# 4. 通过 OpenFang Dashboard 完整测试
# 浏览器打开 http://localhost:4200
# 激活 Manifest Pipeline Hand → 上传文件 → 观察返回结果
```

---

## 四、投票网关 API

### 4.1 A2A Agent Card

```
GET /.well-known/agent.json
```

返回：
```json
{
  "name": "voting-manifest-agent",
  "description": "并发处理 + 投票表决代理",
  "url": "http://voting-gateway:9200/a2a",
  "version": "0.1.0",
  "capabilities": { "streaming": false },
  "skills": [
    { "id": "process-and-vote", "name": "并发处理投票", "description": "并发调用N个Worker并投票表决" }
  ]
}
```

### 4.2 A2A 任务提交

```
POST /a2a
```

请求：
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tasks/send",
  "params": {
    "message": {
      "role": "user",
      "parts": [{"type": "text", "text": "Process file at S3 URL: https://obs.xxx/f.xlsx"}]
    }
  }
}
```

响应：
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "id": "task-uuid",
    "status": { "state": "completed" },
    "messages": [{
      "role": "agent",
      "parts": [{
        "type": "text",
        "text": "投票结果 (8/10 成功, 置信度 75%):\n\n最终答案: ...\n\n--- 投票详情 ---\n..."
      }]
    }]
  }
}
```

### 4.3 管理端点

```
GET /health              # 健康检查
GET /config              # 当前配置（N_REPLICAS, VOTE_STRATEGY 等）
GET /stats               # 投票统计（总请求数、成功率、平均耗时）
```

---

## 五、配置项

| 环境变量 | 默认值 | 说明 |
|----------|--------|------|
| `WORKER_URL` | `http://mock-worker:9100/a2a` | 外部处理 Agent 地址 |
| `N_REPLICAS` | `10` | 并发副本数 |
| `VOTE_STRATEGY` | `exact_match` | 投票策略：exact_match / majority / llm_arbitrate |
| `WORKER_TIMEOUT` | `120` | 单个 Worker 超时（秒） |
| `MIN_SUCCESS` | `3` | 最少成功数，低于此值返回错误 |
| `LLM_API_URL` | - | LLM 仲裁用的 API 地址（llm_arbitrate 策略需要） |
| `LLM_API_KEY` | - | LLM API Key |
| `LLM_MODEL` | `glm-5.1` | LLM 仲裁用的模型 |
| `GATEWAY_PORT` | `9200` | 网关监听端口 |

---

## 六、与现有部署的关系

```
deploy/
├── manifest/                    # 现有的单次处理部署
│   ├── config.toml              #   a2a.external_agents → 直接指向真实 Agent
│   └── ...
│
└── voting/                      # 新的投票集群部署
    ├── config.toml              #   a2a.external_agents → 指向投票网关
    ├── voting-gateway/          #   新增组件
    └── mock-worker/             #   测试用
```

两者完全独立，可以并行部署在不同端口。生产环境用 voting，开发调试用 manifest。

---

## 七、横向扩展

Worker 可以横向扩展：

```yaml
# docker-compose.yml 中加多实例
mock-worker-1: { ... }
mock-worker-2: { ... }
mock-worker-3: { ... }
```

投票网关的 `WORKER_URL` 支持逗号分隔多地址：

```
WORKER_URL=http://worker-1:9100/a2a,http://worker-2:9100/a2a,http://worker-3:9100/a2a
```

网关会轮询（round-robin）分配请求，实现真正的集群化。
