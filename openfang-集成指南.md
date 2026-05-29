# OpenFang 离线部署与 Agent 集成指南

## 一、修改 OpenAPI URL

### 1.1 原理

OpenFang 的 `provider`、`model`、`base_url` 这些字段**无法通过环境变量修改**，必须通过挂载自定义 `config.toml` 配置文件来实现。环境变量只能用来传 API Key。

### 1.2 Docker Compose 配置

将 `config.toml` 放在 `docker-compose.yml` 同级目录下：

```
D:/proj/
├── docker-compose.yml
└── config.toml
```

`docker-compose.yml` 中通过 volume 挂载：

```yaml
services:
  openfang:
    image: openfang:0.6.4-offline
    ports:
      - "4200:4200"
    volumes:
      - openfang-data:/data
      - ./config.toml:/data/config.toml    # 挂载配置文件
    environment:
      - MY_API_KEY=你的Key
    restart: unless-stopped
```

volume 语法：冒号**左边是宿主机路径**，**右边是容器内路径**。离线镜像设置了 `OPENFANG_HOME=/data`，所以容器会读取 `/data/config.toml`。

### 1.3 config.toml 完整写法

注意有两个不同的 "api_key" 概念：

| 字段 | 作用 | 位置 |
|------|------|------|
| `api_key_env` | 指向**环境变量名**，用来连接 LLM 提供商 | `[default_model]` 下 |
| `api_key` | **Dashboard 登录密码**（Bearer token） | 顶层 |

```toml
# ===== LLM 提供商配置 =====
[default_model]
provider = "openai"
model = "glm-5.1"
api_key_env = "MY_API_KEY"
base_url = "http://你的API地址/v1"

[memory]
decay_rate = 0.05

# ===== Embedding driver 的 base_url（必须单独配） =====
# 注意：embedding driver 不读 [default_model].base_url，
# 而是读 [provider_urls] 这个映射表
[provider_urls]
openai = "http://你的API地址/v1"

# ===== Dashboard 登录密码 =====
api_key = "你自定义的密码"
```

### 1.4 常见提供商配置速查

| 提供商 | provider | base_url | 需要 API Key |
|--------|----------|----------|-------------|
| 智谱 GLM | `openai` | `https://open.bigmodel.cn/api/paas/v4` | 是 |
| DeepSeek | `openai` | `https://api.deepseek.com/v1` | 是 |
| OpenAI | `openai` | 不填（默认） | 是 |
| Groq | `groq` | 不填 | 是 |
| Anthropic | `anthropic` | 不填 | 是 |
| Ollama（本地） | `ollama` | 不填 | 否 |
| 内网代理 | `openai` | `http://192.168.x.x:8000/v1` | 看情况 |

> `base_url` 末尾不要加 `/`，否则会拼出双斜杠导致请求失败。

### 1.5 踩坑记录

1. **base_url 没生效** — embedding driver 走的是 `[provider_urls]` 而不是 `[default_model].base_url`，两个都要配
2. **4200 要求输入 API Key** — 这是顶层的 `api_key` 字段控制的，不是 LLM 的 key
3. **挂载后配置没变** — 需 `docker compose down` + `docker compose up -d`，`restart` 不会重新加载 volume 映射
4. **验证容器内配置** — `docker exec openfang cat /data/config.toml` 查看实际读到的文件

---

## 二、Docker Volume 说明

`openfang-data` 是 Docker named volume，不会出现在项目目录下。

### 2.1 查看实际位置

```bash
docker volume inspect openfang-data
```

### 2.2 volume 内容

| 文件/目录 | 说明 |
|-----------|------|
| `config.toml` | 运行时配置 |
| `openfang.db` | SQLite 数据库（Agent、会话、记忆等所有状态） |
| `agents/` | Agent 定义文件 |
| `workspaces/` | Agent 工作目录 |
| `logs/` | 运行日志 |

### 2.3 改成 bind mount（可选）

如果想在宿主机直接看到数据：

```yaml
volumes:
  - D:/proj/openfang-data:/data     # 替代 openfang-data:/data
```

---

## 三、Agent 集成（A2A 协议）

### 3.1 架构说明

OpenFang 的 Dashboard Chat **不会直接调用外部 agent**，所有 agent 间通信都是 LLM 驱动的工具调用：

```
你在 Dashboard 输入消息
       │
       ▼
  OpenFang 本地 Agent 的 LLM
       │
       │  LLM 自己决定用哪个工具
       │
       ├── 普通回复 → 直接返回给你
       ├── agent_send → 调用另一个本地 Agent
       └── a2a_send  → 调用你的外部 Agent
```

### 3.2 外部 Agent 需要实现什么

暴露两个 HTTP 接口，实现 A2A 协议：

| 接口 | 作用 |
|------|------|
| `GET /.well-known/agent.json` | 返回 Agent Card（描述能力） |
| `POST /a2a` | 接收 JSON-RPC 任务请求 |

### 3.3 OpenFang 侧配置

在 `config.toml` 中注册外部 agent：

```toml
[a2a]
enabled = true
listen_path = "/a2a"

[[a2a.external_agents]]
name = "my-deepagent"
url = "http://你的agent地址:9100"
```

### 3.4 关键：agent 模板必须包含 A2A 工具

默认的 agent 模板（assistant、coder 等）**不包含 `a2a_send`**。LLM 只有在工具列表里看到这个工具时，才会知道可以调用外部 agent。

---

## 四、包含 A2A 能力的 Agent 模板

### 4.1 最小化模板

保存为 `agent.toml`，通过 Dashboard 或 API 创建：

```toml
# A2A Agent 模板 — 可以调用外部 Agent
name = "a2a-assistant"
version = "0.1.0"
description = "通用助手，具备 A2A 外部 Agent 调用能力"
author = "you"

[model]
provider = "openai"
model = "glm-5.1"
api_key_env = "MY_API_KEY"
max_tokens = 4096
temperature = 0.7

[model.system_prompt]
text = """你是一个智能助手。

你可以使用以下能力：
- agent_send: 向其他本地 Agent 发送消息
- agent_list: 查看所有本地 Agent
- a2a_discover: 发现外部 Agent
- a2a_send: 向外部 Agent 发送任务

当用户的需求适合交给特定 Agent 处理时，请主动使用 a2a_send 工具调用外部 Agent。
调用时请清晰描述任务要求，并将外部 Agent 的返回结果整理后回复用户。
"""

[capabilities]
tools = [
    "file_read",
    "file_write",
    "memory_store",
    "memory_recall",
    "web_fetch",
    "agent_send",
    "agent_list",
    "a2a_discover",
    "a2a_send"
]
agent_message = ["*"]    # 允许与所有 Agent 通信
shell = false

[resources]
max_tokens_per_turn = 8192
max_concurrent_tools = 5
```

### 4.2 编排器模板（带多 Agent 协调能力）

```toml
name = "a2a-orchestrator"
version = "0.1.0"
description = "编排器，可以创建本地 Agent 并调用外部 Agent 协作完成复杂任务"
author = "you"

[model]
provider = "openai"
model = "glm-5.1"
api_key_env = "MY_API_KEY"
max_tokens = 8192
temperature = 0.5

[model.system_prompt]
text = """你是一个任务编排器。

你的职责是根据用户需求，协调多个 Agent 完成任务：

1. 分析用户需求，判断需要哪些 Agent 协作
2. 使用 agent_spawn 创建需要的本地 Agent
3. 使用 agent_send 给本地 Agent 分配任务
4. 使用 a2a_send 调用外部 Agent（如 deepagent）
5. 收集所有结果，整合后回复用户

可用工具：
- agent_spawn: 创建新的本地 Agent
- agent_send: 给本地 Agent 发消息
- agent_list: 查看所有 Agent
- agent_kill: 终止 Agent
- a2a_discover: 发现外部 Agent
- a2a_send: 向外部 Agent 发送任务
- memory_store / memory_recall: 跨 Agent 共享记忆

请根据任务复杂度合理分配工作，简单任务直接回答，复杂任务拆分后委派。
"""

[capabilities]
tools = [
    "agent_send",
    "agent_spawn",
    "agent_list",
    "agent_kill",
    "agent_find",
    "memory_store",
    "memory_recall",
    "a2a_discover",
    "a2a_send"
]
agent_spawn = true
agent_message = ["*"]

[resources]
max_tokens_per_turn = 16384
max_concurrent_tools = 10
```

### 4.3 通过 API 创建 Agent

```bash
# 方式一：用 curl
curl -X POST http://localhost:4200/api/agents \
  -H "Content-Type: application/json" \
  -d "{\"manifest_toml\": $(cat agent.toml | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}"

# 方式二：用 Python SDK
from openfang_client import OpenFangClient

client = OpenFangClient("http://localhost:4200")
with open("agent.toml") as f:
    client.agents.create(manifest_toml=f.read())
```

### 4.4 外部 Agent 参考实现

OpenFang 项目中有一个完整的 A2A 外部 Agent 示例：

- 服务端：`agents/langchain-code-reviewer/server.py`
- 配置：`agents/langchain-code-reviewer/config.example.toml`

核心只需要实现两个接口：

```python
# GET /.well-known/agent.json — 返回 Agent Card
AGENT_CARD = {
    "name": "my-deepagent",
    "description": "描述你的 Agent 能力",
    "url": "http://你的地址:9100/a2a",
    "version": "0.1.0",
    "capabilities": {
        "streaming": False,
        "pushNotifications": False,
    },
    "skills": [
        {"id": "your_skill", "name": "你的技能名", "description": "技能描述"}
    ]
}

# POST /a2a — 接收 JSON-RPC 任务
# 处理 {"jsonrpc": "2.0", "method": "tasks/send", "params": {...}}
# 返回 {"jsonrpc": "2.0", "result": {"id": "...", "status": "completed", ...}}
```

---

## 五、完整部署 Checklist

```bash
# 1. 准备配置文件
cat > D:/proj/config.toml << 'EOF'
[default_model]
provider = "openai"
model = "glm-5.1"
api_key_env = "MY_API_KEY"
base_url = "http://你的API地址/v1"

[memory]
decay_rate = 0.05

[provider_urls]
openai = "http://你的API地址/v1"

api_key = "你的Dashboard密码"

[a2a]
enabled = true
listen_path = "/a2a"

[[a2a.external_agents]]
name = "my-deepagent"
url = "http://你的agent地址:9100"
EOF

# 2. 启动
cd D:/proj
docker compose up -d

# 3. 验证
curl -s http://localhost:4200/api/health

# 4. 检查外部 Agent 是否被发现
curl -s http://localhost:4200/api/a2a/agents

# 5. 创建带 A2A 能力的 Agent（用上面的模板）
curl -X POST http://localhost:4200/api/agents \
  -H "Content-Type: application/json" \
  -d '{"manifest_toml": "..."}'

# 6. 在 Dashboard 聊天中测试
# 访问 http://localhost:4200/ ，选择刚创建的 Agent，
# 发送 "请用 deepagent 帮我做 XXX"
```
