# Manifest Hand 部署指南

## 架构

```
┌─────────────────────────────────────────────────────────┐
│  用户 (浏览器)                                            │
│  http://localhost:4200                                    │
└──────────────┬──────────────────────────────────────────┘
               │ 上传文件 (xlsx/docx/zip/image/...)
               ▼
┌──────────────────────────────────────────────────────────┐
│  OpenFang (openfang:0.6.4-offline-manifest)              │
│                                                          │
│  1. 检测到 Manifest Hand agent                           │
│  2. 附件作为 [FILE_ATTACHMENT] 文本块发给 agent           │
│  3. Agent 调用 MCP 工具 → mcp-obs-s3:3100                │
│  4. Agent 通过 A2A 发送 S3 URL 给外部 manifest agent     │
│  5. 下载 manifest → 保存到 output/                       │
│  6. 用户通过 /api/agents/{id}/output/{file} 下载         │
└──────────┬───────────────────────────────────────────────┘
           │ MCP (Streamable HTTP)
           ▼
┌──────────────────────────────────────────────────────────┐
│  MCP OBS S3 (mcp-obs-s3:1.1.0)                          │
│  HTTP :3100 — s3_upload / s3_download / s3_list / url    │
└──────────┬───────────────────────────────────────────────┘
           │
           ▼
┌──────────────────────────────────────────────────────────┐
│  华为云 OBS                                              │
└──────────────────────────────────────────────────────────┘
```

## 目录结构

```
deploy/manifest/
├── docker-compose.yml      # Docker Compose 编排文件
├── config.toml             # OpenFang 配置（LLM、MCP server）
├── .env.example            # 环境变量模板
├── hands/
│   └── manifest/
│       ├── HAND.toml       # Manifest Hand 定义
│       └── SKILL.md        # Hand 技能文档（工作流指令）
└── README.md               # 本文件
```

## 部署步骤

### 1. 加载镜像

```bash
# 从 tar.gz 加载（离线环境）
docker load < openfang-0.6.4-offline-manifest.tar.gz
docker load < mcp-obs-s3-1.1.0.tar.gz

# 验证镜像存在
docker images | grep -E "openfang|mcp-obs-s3"
```

### 2. 配置环境变量

```bash
cd deploy/manifest

# 复制模板并编辑
cp .env.example .env
vim .env
```

必填项：
- `OPENAI_API_KEY` — LLM API Key
- `OBS_ACCESS_KEY_ID` — 华为云 AK
- `OBS_SECRET_ACCESS_KEY` — 华为云 SK
- `OBS_ENDPOINT` — OBS 终端节点
- `OBS_BUCKET` — 桶名称

### 3. （可选）修改 config.toml

默认配置使用 GLM-5.1 模型 + OpenAI 兼容接口。如需更改 LLM 或添加 A2A 外部 agent，编辑 `config.toml`。

### 4. 启动服务

```bash
docker compose up -d

# 查看日志
docker compose logs -f

# 检查健康状态
docker compose ps
curl http://localhost:4200/api/health
```

### 5. 激活 Manifest Hand

1. 浏览器访问 http://localhost:4200
2. 进入 **Hands** 页面
3. 找到 **Manifest Hand**，点击 **Activate**
4. 创建一个新的 chat，选择 Manifest Hand agent

### 6. 测试

在 chat 界面上传一个文件（xlsx、docx、zip 等），观察 agent 是否：
1. 接收到 `[FILE_ATTACHMENT]` 文本块（而非 "Vision not supported" 警告）
2. 调用 MCP `s3_upload` 上传文件
3. 通过 A2A 发送给外部 manifest agent
4. 下载 manifest 并提供下载链接

## 数据流

```
用户上传 report.xlsx
  → OpenFang 保存到 /tmp/openfang_uploads/{uuid}
  → Hand agent 收到: [FILE_ATTACHMENT] filename="report.xlsx" path="/tmp/openfang_uploads/xxx"
  → agent 调用 MCP s3_upload({ file_path: "/tmp/openfang_uploads/xxx" })
  → mcp-obs-s3 上传到 OBS，返回 S3 URL
  → agent 调用 a2a_send({ agent_name: "manifest-agent", message: "S3 URL: ..." })
  → 外部 agent 处理完成，返回 manifest S3 URL
  → agent 调用 MCP s3_download({ key: "manifest.json", output_path: "output/manifest_report.json" })
  → 用户下载: GET /api/agents/{id}/output/manifest_report.json
```

## 排查问题

| 现象 | 原因 | 解决 |
|------|------|------|
| "Vision not supported" 警告 | Hand 未激活，附件走了 base64 图片路径 | 在 Dashboard 激活 Manifest Hand |
| MCP 工具不可用 | config.toml 未正确挂载 | 检查 `docker compose exec openfang cat /etc/openfang/config.toml` |
| OBS 上传失败 | 凭证或 endpoint 配置错误 | 检查 .env 中的 OBS_* 变量 |
| A2A 超时 | 外部 manifest agent 未启动或 URL 错误 | 检查 config.toml 中的 `[[a2a.external_agents]]` |
| 找不到 Hand | hands 目录未正确挂载 | 检查 `docker compose exec openfang ls /opt/openfang/hands/manifest/` |

## 端口说明

| 端口 | 服务 | 说明 |
|------|------|------|
| 4200 | OpenFang | Web Dashboard + API |
| 3100 | MCP OBS S3 | MCP Streamable HTTP（容器内部，不暴露到宿主机） |
