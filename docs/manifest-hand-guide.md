# Manifest Hand — 文件转 Manifest 管道

## 概述

Manifest Hand 是一个 OpenFang Hand，实现文件到 manifest 的自动转换管道。用户在 chat 界面上传文件，Hand 自动编排：上传 S3 → A2A 发给外部 agent → 下载 manifest → 提供下载链接。

## 架构

```
用户上传文件 (chat UI)
  │
  ├─ POST /api/agents/{id}/upload → 本地临时存储
  │
  ├─ POST /api/agents/{id}/message { attachments }
  │   └─ send_message() 检测到 Hand agent
  │       └─ resolve_hand_attachments() → 文本元数据块（非 base64，不做多模态处理）
  │
  └─ Agent 自动执行多步骤工作流：
      1. MCP s3_upload → 上传文件到 S3，获取 URL
      2. a2a_send → 将 S3 URL 发送给外部 manifest agent
      3. 等待响应 → 获取 manifest 的 S3 URL
      4. MCP s3_download → 从 S3 下载 manifest
      5. file_write → 保存到 workspace output/ 目录
      6. 回复下载链接 → 用户在 chat 点击下载
```

## 支持的文件类型

| 分类 | 格式 | 扩展名 |
|------|------|--------|
| 图片 | PNG, JPEG, GIF, WebP | `.png` `.jpg` `.gif` `.webp` |
| 文本 | TXT, CSV, MD, JSON | `.txt` `.csv` `.md` `.json` |
| Office | XLSX, DOCX, PPTX, XLS, DOC | `.xlsx` `.docx` `.pptx` `.xls` `.doc` |
| 压缩包 | ZIP, GZIP | `.zip` `.gz` |
| 其他 | PDF | `.pdf` |

### 动态扩展文件类型

在 `config.toml` 中添加 `upload_extra_types` 即可支持新文件类型，无需改代码：

```toml
upload_extra_types = [
    "application/x-7z-compressed",   # .7z
    "application/rtf",                # .rtf
    "application/vnd.ms-powerpoint",  # .ppt
]
```

## 并发隔离

多用户同时使用时 manifest 不会串：
- 每个 Hand 激活 = 独立 agent 实例，独立 workspace
- A2A 调用同步阻塞，不会交叉
- output 文件按 agent_id 隔离，文件名包含原始文件名前缀

## 离线镜像使用指南

### 1. 构建镜像

```bash
docker build -f Dockerfile.offline -t openfang:0.6.4-offline .
```

或使用 docker-compose：

```bash
docker compose -f docker-compose.offline.yml build
```

### 2. 配置

编辑 `config.toml` 挂载到容器的 `/data/config.toml`：

```toml
# LLM 配置
[default_model]
provider = "openai"
model = "glm-5.1"
api_key_env = "OPENAI_API_KEY"
base_url = "https://open.bigmodel.cn/api/paas/v4"

# S3 MCP Server（封装了 S3 上传下载逻辑）
[[mcp_servers]]
name = "s3"
transport = { type = "http", url = "http://s3-mcp-server:3000/mcp" }
timeout_secs = 120

# A2A 配置（manifest 处理可能较慢，建议 300s）
[a2a]
enabled = true
timeout_secs = 300

# 外部 manifest agent
[[a2a.external_agents]]
name = "manifest-agent"
url = "https://your-manifest-agent.example.com"

# 如需额外文件类型
# upload_extra_types = ["application/x-7z-compressed"]
```

### 3. 启动

```bash
# 使用 docker compose
OPENAI_API_KEY=your-key docker compose -f docker-compose.offline.yml up -d

# 或直接 docker run
docker run -d \
  --name openfang \
  -p 4200:4200 \
  -v openfang-data:/data \
  -v ./hands:/opt/openfang/hands:ro \
  -e OPENAI_API_KEY=your-key \
  openfang:0.6.4-offline
```

### 4. 激活 Manifest Hand

访问 Dashboard `http://localhost:4200`，进入 Hands 页面，找到 **Manifest Hand** 并激活。配置：
- `manifest_agent_name`：外部 A2A agent 名称（默认 `manifest-agent`）
- `manifest_agent_url`：直接 URL（优先于名称）
- `s3_upload_tool`：S3 上传 MCP 工具名（默认 `mcp_s3_upload`）
- `s3_download_tool`：S3 下载 MCP 工具名（默认 `mcp_s3_download`）

### 5. 使用

1. 在 chat 界面选择 Manifest Hand 的 agent
2. 点击附件按钮上传文件（支持拖拽）
3. 发送消息，Hand 自动执行管道
4. 响应中包含下载链接，点击下载 manifest

### 6. API 端点

| 端点 | 方法 | 说明 |
|------|------|------|
| `GET /api/agents/{id}/output` | GET | 列出 agent 的 output 文件 |
| `GET /api/agents/{id}/output/{filename}` | GET | 下载 output 文件 |
| `POST /api/agents/{id}/upload` | POST | 上传附件 |
| `POST /api/agents/{id}/message` | POST | 发送消息（含附件） |

## 文件结构

```
openfang/
├── hands/
│   └── manifest/
│       ├── HAND.toml      # Hand 定义（工具、配置、系统 prompt）
│       └── SKILL.md       # 技能文档（工作流详细指令）
├── Dockerfile.offline     # 离线镜像构建
├── docker-compose.offline.yml
└── crates/
    ├── openfang-api/src/routes.rs      # 附件解析 + output 端点
    ├── openfang-api/src/server.rs      # 路由注册
    ├── openfang-api/static/            # 前端文件类型支持
    └── openfang-types/src/config.rs    # upload_extra_types 配置
```

## S3 MCP Server 说明

S3 MCP Server 是独立于 OpenFang 的外部服务，自行管理 S3 凭证和配置。需提供两个工具：

| 工具 | 输入 | 输出 |
|------|------|------|
| `s3_upload` | `{ "path": "/local/file/path", "filename": "report.xlsx" }` | `{ "url": "https://s3.../report.xlsx", "key": "..." }` |
| `s3_download` | `{ "url": "https://s3.../manifest.json", "output_path": "output/manifest_report.json" }` | `{ "file_path": "...", "size": 1024 }` |
