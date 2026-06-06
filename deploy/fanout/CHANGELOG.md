# FanOut 投票集群变更日志

## v1 — 2024-06 初始方案

- 完整 FanOut 原生投票集群设计
- 3 个 Agent 模板：uploader / processor / voter
- 1 个 Workflow 定义：13 步编排（1 上传 + 10 并行处理 + 1 收集 + 1 投票）
- 4 个脚本：init / run / status / cleanup
- 需要 OpenFang 源码补丁：FanOut 错误容忍（~6 行改动）
