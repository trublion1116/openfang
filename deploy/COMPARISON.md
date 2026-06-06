# 方案对比：投票网关 vs 原生 FanOut

> 两种实现「10 Agent 并发处理 + 投票表决」的完整对比

---

## 一、架构对比

### 方案 A：投票网关（外部）

```
Dashboard → OpenFang → manifest-pipeline Hand
                            │
                            ▼ a2a_send
                     ┌─────────────┐
                     │ 投票网关     │  ← Python 容器，对 OpenFang 来说是普通外部 Agent
                     │ (voting-gw) │
                     └──────┬──────┘
                     ┌──────┼──────┐
                     ▼      ▼      ▼
                  Worker  Worker  Worker  ← N 个 HTTP 调用（asyncio.gather）
                  (×10)   (×10)   (×10)
                     │      │      │
                     └──────┼──────┘
                            ▼
                        投票裁决
                            │
                            ▼
                     返回最终结果
```

### 方案 B：原生 FanOut（内部）

```
Dashboard/脚本 → OpenFang Workflow API
                     │
                     ▼
              ┌─ Step 1: uploader Agent (Sequential)
              │    → MCP S3 上传 → s3_url 变量
              │
              ├─ Step 2-11: processor-1..10 Agent (FanOut ×10)
              │    → 各自 a2a_send 到外部 manifest-agent
              │    → tokio join_all 真正并行
              │    ⚠️ 所有 FanOut step 接收相同的 {{input}}（官方文档确认）
              │
              ├─ Step 12: Collect（自动拼接 10 个结果，用 "---" 分隔）
              │    ⚠️ 不执行 Agent，纯数据拼接（官方文档确认）
              │
              └─ Step 13: voter Agent (Sequential)
                   → 分析 10 个结果，投票输出
```

### 官方文档确认的关键行为

> 摘自 `docs/workflows.md`

1. **FanOut 并行输入一致**：所有连续的 FanOut step 接收 **相同的 `{{input}}`**
2. **FanOut 失败立即中止**："If any fan-out step fails or times out, the entire workflow fails immediately."
3. **Collect 不执行 Agent**："It does not execute an agent -- it is a data-only step"
4. **Collect 只是 join**："joins all accumulated outputs with the separator `\"\\n\\n---\\n\\n\"`"
5. **Workflow API 是同步阻塞的**："The call blocks until the workflow completes or fails"
6. **每步独立 timeout**："Fan-out steps each get their own independent timeout"
7. **运行记录上限 200 条**：FIFO 淘汰已完成的
8. **A2A Client 30s 超时**（`docs/mcp-a2a.md`）：长任务需用 Working 状态 + 轮询

---

## 二、逐项对比

| 维度 | 方案 A：投票网关 | 方案 B：原生 FanOut |
|------|-----------------|-------------------|
| **代码改动** | 0 行 OpenFang 代码 | ~6 行（FanOut 错误容忍） |
| **新增组件** | 2 个容器（voting-gw + mock-worker） | 0 个容器 |
| **Agent 数量** | 1 个（manifest-pipeline Hand） | 12 个（1 uploader + 10 processor + 1 voter） |
| **OpenFang 改动** | 只改 config.toml 1 行 URL | 需改 workflow.rs + 重编译镜像 |
| **并发机制** | Python asyncio.gather | Rust tokio join_all |
| **投票逻辑** | Python 代码（精确） | voter Agent prompt（LLM 判断） |
| **触发方式** | Dashboard 聊天直接触发 | API curl / 脚本（Dashboard 不支持） |
| **可观测性** | 网关自身日志 | Workflow Run 完整状态机 + step_results |
| **资源占用** | +1 Python 容器（~50MB RAM） | 12 个 Agent 共享 OpenFang 进程 |
| **投票策略** | 3 种可配置（exact/majority/llm） | 1 种（LLM 判断，靠 prompt） |
| **容错** | MIN_SUCCESS 阈值可配置 | 需改源码才能容忍部分失败 |
| **与现有部署兼容** | ✅ 零改动，只改 URL | ❌ 需要新镜像 |
| **部署难度** | ⭐ 简单，docker compose up | ⭐⭐⭐ 需编译 Rust + 构建镜像 |
| **维护成本** | 独立 Python 服务，易调试 | 在 OpenFang 内部，需要 Rust 能力 |
| **LLM Token 消耗** | 1 次（manifest-pipeline Hand）+ 网关内 LLM 投票 | 12 次（12 个 Agent 各自调 LLM） |

---

## 三、核心差异详解

### 3.1 投票精度

**方案 A（投票网关）**：用 Python 代码做投票，可以精确实现：
- `exact_match`：字符串完全一致
- `majority`：多数表决（可配相似度阈值）
- `llm_arbitrate`：结果分歧大时调 LLM 仲裁

**方案 B（原生 FanOut）**：靠 voter Agent 的 system prompt 做 LLM 投票：
- 优点：能理解语义相似性（同一结果的不同表述）
- 缺点：LLM 可能误判，不够确定性
- 温度设 0.1 降低随机性，但仍是概率性的

### 3.2 触发方式

**方案 A**：
- Dashboard 聊天界面直接上传文件即可
- manifest-pipeline Hand 零改动，用户体验不变
- a2a_send 自动走投票网关

**方案 B**：
- 需要 curl 调 Workflow API
- Dashboard 聊天界面不支持触发 Workflow（没有 workflow_run 工具）
- 如需 Dashboard 触发，需额外改 ~30 行加工具

### 3.3 资源模型

**方案 A**：
```
OpenFang 进程 (1 Agent)  +  voting-gateway 容器  +  mock-worker/外部Agent
       ↓                          ↓
   1 次 LLM 调用           10 次 HTTP + 1 次 LLM 投票
```

**方案 B**：
```
OpenFang 进程 (12 Agent)  +  外部 manifest-agent
       ↓
   12 次 LLM 调用（uploader + 10 processor + voter）
```

方案 B 的 LLM 调用次数是方案 A 的 ~6 倍。

### 3.4 容错能力

**方案 A**：
- `MIN_SUCCESS` 环境变量控制最少成功数（默认 3）
- 某个 Worker 超时/失败不影响其他
- 结果不足时直接报错

**方案 B**：
- **必须改源码**才能容忍部分失败（当前代码一个失败全部中止）
- 改动很小（~6 行），但需要重新编译

---

## 四、适用场景

### 选方案 A（投票网关）如果你：

- ✅ 不想改 OpenFang 源码
- ✅ 希望快速验证投票效果
- ✅ 需要精确的投票逻辑（不是 LLM 判断）
- ✅ 想通过 Dashboard 聊天触发
- ✅ 团队没有 Rust 编译能力

### 选方案 B（原生 FanOut）如果你：

- ✅ 希望 OpenFang 自身具备集群能力
- ✅ 有 Rust 编译和镜像构建能力
- ✅ 需要完整的 Workflow 可观测性
- ✅ 长期计划给 OpenFang 提 PR
- ✅ 能接受 API 触发而非 Dashboard 聊天

---

## 五、混合方案（推荐）

先用方案 A 验证投票效果（快速上线），同时准备方案 B 的 OpenFang PR。

验证路径：
1. **Week 1**：部署投票网关，mock-worker 测试
2. **Week 2**：替换 mock-worker 为真实 manifest-agent
3. **Week 3**：如果效果好，开始改 OpenFang FanOut 代码
4. **Week 4**：并行运行两套方案对比结果

---

## 六、文件清单

### 方案 A — deploy/voting/
```
voting/
├── README.md                 # 方案设计文档
├── CHANGELOG.md
├── docker-compose.yml        # 4 服务（openfang + voting-gw + mock-worker + mcp-obs-s3）
├── .env.example
├── config.toml
├── hands/manifest-pipeline/  # 从现有部署复制，零改动
├── voting-gateway/
│   ├── Dockerfile
│   └── server.py             # ~413 行，A2A + asyncio + 投票
├── mock-worker/
│   ├── Dockerfile
│   └── server.py             # 模拟 Agent（70% 正确）
└── scripts/
    ├── start.sh
    ├── stop.sh
    └── verify.sh
```

### 方案 B — deploy/fanout/
```
fanout/
├── README.md                 # 本文件（详细设计 + 源码分析）
├── CHANGELOG.md
├── docker-compose.yml        # 2 服务（openfang + mcp-obs-s3）
├── .env.example
├── config.toml
├── agents/
│   ├── uploader/agent.toml   # S3 上传 Agent
│   ├── processor/agent.toml  # 处理 Agent 模板（×10）
│   └── voter/agent.toml      # 投票仲裁 Agent
├── workflow.json             # Workflow 定义（13 步）
├── scripts/
│   ├── init.sh               # 创建 12 Agent + 注册 Workflow
│   ├── run.sh                # 触发执行
│   ├── status.sh             # 查看状态
│   └── cleanup.sh            # 清理
└── verify.sh                 # 端到端验证
```
