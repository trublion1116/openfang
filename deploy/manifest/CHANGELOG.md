# OpenFang 离线 Manifest 镜像 Changelog

基于上游 `openfang v0.6.4` (`3cce1eb`) 的定制构建。

---

## v11 — 待构建

**镜像**: `openfang:0.6.4-offline-manifest-v11`
**日期**: 2026-06-03

- **feat**: 新增 `manifest-pipeline` hand，在 S3 上传后通过 A2A 调用外部 agent 做数据处理，返回可点击下载链接
- **fix**: `a2a_send` 工具现在读取 config.toml 的 `ssrf_allowed_hosts` 配置，允许放行指定的内网/私有地址
- **fix**: `upload_max_size_mb` 配置位置说明更正（config.toml 而非环境变量）

**配置变更** (需在部署环境手动更新 config.toml):
```toml
# A2A 外部 agent
[a2a]
enabled = true

[[a2a.external_agents]]
name = "manifest-agent"
url = "https://your-manifest-agent.example.com"
```

**新增文件**:
- `hands/manifest-pipeline/HAND.toml`
- `hands/manifest-pipeline/SKILL.md`

---

## v10

**镜像**: `openfang:0.6.4-offline-manifest-v10`
**日期**: 2026-06-02

- **feat**: 上传文件大小限制可通过 config.toml 的 `upload_max_size_mb` 配置（默认 10 MB）
- **fix**: HTTP body 大小限制从 axum 默认 2MB 提升到 10MB

---

## v9

**镜像**: `openfang:0.6.4-offline-manifest-v9`
**日期**: 2026-06-01

- **fix**: WebSocket 消息路径中正确处理 hand 文件附件
- **refactor**: 提取 `inject_hand_attachments_into_message()` 共享函数，统一 HTTP/WS 附件注入逻辑
- 文件附件数据流文档补充

---

## v8

**镜像**: `openfang:0.6.4-offline-manifest-v8`
**日期**: 2026-06-01

- **fix**: 将 FILE_ATTACHMENT 直接注入到消息文本中供 hand agent 读取
- **fix**: streaming 端点添加 hand 附件处理
- 添加 MCP 工具调用参数日志

---

## v7

**镜像**: `openfang:0.6.4-offline-manifest-v7`
**日期**: 2026-06-01

- **fix**: 剥离前端发送的 `[File: xxx]` 标签，避免 hand agent 收到重复/冲突的文件信息
- 添加文件附件流程详细日志（排查上传问题用）

---

## v6

**镜像**: `openfang:0.6.4-offline-manifest-v6`
**日期**: 2026-06-01

- **fix**: 移除 system_prompt 中的示例路径，防止 LLM 直接复制占位路径而非使用真实路径

---

## v5

**镜像**: `openfang:0.6.4-offline-manifest-v5`
**日期**: 2026-06-01

- **fix**: 限制 manifest hand 只能使用 `mcp_obs_s3_s3_upload` 工具，禁止 `shell_exec` 等
- **fix**: 上传文件拷贝到 agent workspace 目录，满足沙箱文件访问要求

---

## v4 — 跳过（无对应镜像）

- **fix**: 简化 manifest hand 为纯 S3 上传 + 共享 volume 方案，去掉 A2A 环节
- 此版本未打出正式镜像，改动合入 v5

---

## v3

**镜像**: `openfang:0.6.4-offline-manifest-v3`
**日期**: 2026-06-01

- **fix**: Dockerfile.offline 构建阶段添加 `COPY hands`，确保 hand 定义文件打入镜像
- 新增 `deploy/` 部署目录结构（config.toml、docker-compose.yml、hands/）

---

## v2

**镜像**: `openfang:0.6.4-offline-manifest-v2`
**日期**: 2026-06-01

- **fix**: WebSocket 消息路径支持 hand agent 文件附件处理
- 修复 hand agent 通过 WS 发送消息时收不到 FILE_ATTACHMENT 的问题

---

## v1

**镜像**: `openfang:0.6.4-offline-manifest`
**日期**: 2026-05-30

- **feat**: 新增 manifest hand — 文件转 manifest 管道（S3 上传 + A2A 调用外部 agent）
- 初始部署方案：`deploy/manifest/` 目录，含 config.toml、docker-compose.yml、hands/

---

## v0 (前置版本)

**镜像**: `openfang:0.6.4-offline` / `openfang:0.6.4-offline-a2a-timeout`
**日期**: 2026-05-30

- 基于上游 v0.6.4 构建离线镜像（Dockerfile.offline，debian:bookworm-slim）
- 离线部署支持（`docker compose -f docker-compose.offline.yml`）
- A2A 请求超时可配置
