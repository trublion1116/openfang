# 投票集群 Changelog

## v1 — 初始版本

**日期**: 2026-06-04

### 新增

- 投票网关 (`voting-gateway/`)
  - 实现 A2A 协议 (Agent Card + tasks/send + tasks/get)
  - 支持三种投票策略：exact_match / majority / llm_arbitrate
  - 并发调用 N 个 Worker（asyncio.gather）
  - 部分失败容忍（MIN_SUCCESS 阈值）
  - 管理端点：/health /config /stats
- Mock Worker (`mock-worker/`)
  - 模拟外部处理 Agent，实现 A2A 协议
  - 可配置正确率、超时率、延迟
- 部署文件
  - docker-compose.yml（4 个服务：openfang + mcp-obs-s3 + voting-gateway + mock-worker）
  - config.toml（A2A 指向投票网关）
  - .env.example
  - hands/manifest-pipeline/（复用现有 Hand，零改动）
- 脚本
  - scripts/start.sh — 一键启动
  - scripts/stop.sh — 一键停止
  - scripts/verify.sh — 自动化验证

### 架构

```
用户 → OpenFang Hand → a2a_send → 投票网关 → ×N Worker → 投票 → 返回
```

OpenFang 零改动，只改 config.toml 里 1 行 A2A URL。
