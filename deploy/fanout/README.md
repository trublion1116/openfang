# OpenFang 原生 FanOut 投票集群方案

> 目标：用 OpenFang 内置的 Workflow FanOut 实现多 Agent 并发处理 + 投票
> 原则：最小化 OpenFang 代码改动（~20 行），利用已有的 Workflow 引擎

---

## 一、原理

### 1.1 OpenFang Workflow 引擎

OpenFang 内置了 Workflow 引擎（`crates/openfang-kernel/src/workflow.rs`），支持 5 种步骤模式：

```
StepMode::Sequential     — 串行执行
StepMode::FanOut         — 并行执行（tokio join_all）
StepMode::Collect        — 收集 FanOut 结果并拼接
StepMode::Conditional    — 条件跳过
StepMode::Loop           — 循环执行
```

### 1.2 FanOut 并行机制

FanOut 是 **真正的 tokio 异步并行**：

```rust
// workflow.rs L534-571
StepMode::FanOut => {
    // 1. 收集所有连续的 FanOut step
    let mut fan_out_steps = vec![(i, step)];
    while j < workflow.steps.len() {
        if matches!(workflow.steps[j].mode, StepMode::FanOut) {
            fan_out_steps.push((j, &workflow.steps[j]));
            j += 1;
        } else { break; }
    }

    // 2. 每个 step 引用一个不同的 Agent，创建独立的 tokio future
    for (idx, fan_step) in &fan_out_steps {
        futures.push(tokio::time::timeout(
            timeout_dur,
            send_message(agent_id, prompt),  // ← 发给不同 Agent
        ));
    }

    // 3. join_all — 所有 future 同时开始执行
    let results = futures::future::join_all(futures).await;
}
```

**关键：** 每个 FanOut step 引用不同的 Agent 实例。因为 per-Agent 有 Mutex 锁
（`kernel.rs` L1898），同一 Agent 不能并行处理两条消息。所以 N 个并行 = N 个 Agent。

### 1.3 为什么需要小改代码

FanOut 有两个硬伤需要修复：

**问题 A：FanOut 不容忍部分失败**

```rust
// workflow.rs L598-607（当前代码）
Ok(Err(e)) => {
    r.state = WorkflowRunState::Failed;   // 一个失败 → 全部中止
    return Err(error_msg);                // 直接 return
}
Err(_) => {                               // 超时也是
    r.state = WorkflowRunState::Failed;
    return Err(error_msg);
}
```

虽然 `WorkflowStep` 结构体有 `error_mode` 字段（支持 Fail/Skip/Retry），
但 FanOut 分支 **完全不看 error_mode**，永远 return Err 中止。

投票场景 10 个里挂 1-2 个很正常，应该用剩余的结果继续投票。

**问题 B：Collect 只做字符串拼接**

```rust
// workflow.rs L635-642（当前代码）
StepMode::Collect => {
    current_input = all_outputs.join("\n\n---\n\n");  // 就这一行
}
```

没有投票逻辑。这个可以通过 voter Agent 的 system prompt 补偿，不需要改代码。

---

## 二、架构设计

### 2.1 整体流程

```
用户上传文件 → curl/脚本触发 Workflow API
  │
  ├─ Step 1 (Sequential): uploader Agent
  │   → MCP mcp_obs_s3_s3_upload 上传文件
  │   → 输出 S3 URL
  │
  ├─ Step 2-11 (FanOut ×10): processor-1 ~ processor-10
  │   → 每个 Agent 收到 {{s3_url}} 变量
  │   → a2a_send 到外部 manifest-agent
  │   → 返回处理结果
  │   ⚡ 10 个 Agent 真正并行（tokio join_all）
  │
  ├─ Step 12 (Collect): 自动拼接 10 个结果
  │
  └─ Step 13 (Sequential): voter Agent
      → 分析拼接后的 10 个结果
      → 投票表决，输出最终答案
```

### 2.2 组件清单

| 组件 | 数量 | 说明 |
|------|------|------|
| uploader Agent | 1 | 只做 S3 上传，不做 a2a_send |
| processor Agent | 10 | 同配置不同名字，各做 1 次 a2a_send |
| voter Agent | 1 | 分析 10 个结果，投票表决 |
| Workflow 定义 | 1 | 13 个 step 的编排 |
| **总计 Agent** | **12** | |

### 2.3 数据流

```
                      Workflow input
                      "path=/tmp/xxx filename=report.xlsx"
                            │
                            ▼
┌─────────────────────────────────────────────┐
│  Step 1: uploader (Sequential)              │
│  prompt: "上传这个文件: {{input}}"            │
│  Agent 工具: MCP mcp_obs_s3_s3_upload        │
│  output_var: "s3_url"                       │
│  输出: "s3_url=https://obs.xxx/report.xlsx" │
└──────────────────┬──────────────────────────┘
                   │ variables["s3_url"] = "https://obs.xxx/report.xlsx"
                   ▼
┌─────────────────────────────────────────────┐
│  Step 2-11: processor-1..10 (FanOut ×10)    │
│  prompt: "处理文件: {{s3_url}}"              │
│  Agent 工具: a2a_send, a2a_discover          │
│                                             │
│  processor-1 ──a2a_send──→ 外部Agent ──┐    │
│  processor-2 ──a2a_send──→ 外部Agent ──┤    │
│  ...                                    ├ 并行│
│  processor-10──a2a_send──→ 外部Agent ──┘    │
│                                             │
│  每个 Agent 各自返回 1 个结果                  │
└──────────────────┬──────────────────────────┘
                   │ all_outputs = [result1, result2, ..., result10]
                   ▼
┌─────────────────────────────────────────────┐
│  Step 12: (Collect)                         │
│  拼接: result1\n\n---\n\nresult2\n...       │
└──────────────────┬──────────────────────────┘
                   │ current_input = 拼接后的全部结果
                   ▼
┌─────────────────────────────────────────────┐
│  Step 13: voter (Sequential)                │
│  prompt: "以下是10个Agent的处理结果，请投票：  │
│           {{input}}"                        │
│  temperature: 0.1（确保投票逻辑稳定）          │
│  输出: 投票结果 + 置信度                       │
└──────────────────┬──────────────────────────┘
                   ▼
              Workflow output
              最终投票结果
```

---

## 三、代码改动

### 3.1 必须改的：FanOut 错误容忍（3 行）

文件：`crates/openfang-kernel/src/workflow.rs`

将 L598-621 的两个 `return Err` 改为 `continue`：

```rust
// 改动前（L598-607）:
Ok(Err(e)) => {
    let error_msg = format!("FanOut step '{}' failed: {}", step_name, e);
    warn!(%error_msg);
    if let Some(r) = self.runs.write().await.get_mut(&run_id) {
        r.state = WorkflowRunState::Failed;
        r.error = Some(error_msg.clone());
        r.completed_at = Some(Utc::now());
    }
    return Err(error_msg);  // ← 改这里
}

// 改动后:
Ok(Err(e)) => {
    let error_msg = format!("FanOut step '{}' failed: {}", step_name, e);
    warn!(%error_msg);
    // 记录失败但继续执行（投票场景需要容忍部分失败）
    if let Some(r) = self.runs.write().await.get_mut(&run_id) {
        r.step_results.push(StepResult {
            step_name: step_name.clone(),
            agent_id: agent_id.to_string(),
            agent_name: agent_name.clone(),
            output: format!("[FAILED] {}", error_msg),
            input_tokens: 0,
            output_tokens: 0,
            duration_ms,
        });
    }
    // 不 return Err，继续处理其他结果
}

// 改动前（L609-621）:
Err(_) => {
    // ... 同样改为 continue 而非 return Err
}

// 改动后:
Err(_) => {
    let error_msg = format!("FanOut step '{}' timed out after {}s", step_name, fan_step.timeout_secs);
    warn!(%error_msg);
    if let Some(r) = self.runs.write().await.get_mut(&run_id) {
        r.step_results.push(StepResult {
            step_name: step_name.clone(),
            agent_id: agent_id.to_string(),
            agent_name: agent_name.clone(),
            output: format!("[TIMEOUT] {}", error_msg),
            input_tokens: 0,
            output_tokens: 0,
            duration_ms,
        });
    }
    // 不 return Err，继续
}
```

**改动量：** 删除 4 行（return Err 相关），新增 ~10 行（push 失败记录），净增 ~6 行。

### 3.2 可选改：给 FanOut 加 error_mode 支持

如果要更优雅，可以让 FanOut 也检查 step 的 `error_mode` 字段：

```rust
Ok(Err(e)) => {
    let error_msg = format!("FanOut step '{}' failed: {}", step_name, e);
    warn!(%error_msg);
    
    // 尊重 step 的 error_mode 配置
    match &fan_step.error_mode {
        ErrorMode::Skip => {
            // 跳过，继续
        }
        ErrorMode::Retry { max_retries } => {
            // TODO: 重试逻辑
        }
        ErrorMode::Fail => {
            // 原来的行为：中止
            if let Some(r) = self.runs.write().await.get_mut(&run_id) {
                r.state = WorkflowRunState::Failed;
                r.error = Some(error_msg.clone());
                r.completed_at = Some(Utc::now());
            }
            return Err(error_msg);
        }
    }
}
```

**改动量：** ~20 行。

---

## 四、部署文件

### 4.1 文件结构

```
deploy/fanout/
├── README.md                    # 本文件
├── docker-compose.yml           # 部署编排
├── .env.example
├── config.toml                  # OpenFang 配置
├── agents/
│   ├── uploader/
│   │   └── agent.toml           # S3 上传专用 Agent
│   ├── processor.toml           # 处理 Agent 模板（脚本会复制 ×10）
│   └── voter/
│       └── agent.toml           # 投票仲裁 Agent
├── workflow.json                # Workflow 定义
├── scripts/
│   ├── init.sh                  # 初始化：创建 12 个 Agent + 注册 Workflow
│   ├── run.sh                   # 触发 Workflow 执行
│   ├── status.sh                # 查看运行状态
│   └── cleanup.sh               # 清理所有 Agent + Workflow
└── verify.sh                    # 验证脚本
```

### 4.2 与现有部署的关系

```
deploy/
├── manifest/              # 现有单次处理部署（v12）
├── voting/                # 方案 A：外部投票网关
└── fanout/                # 方案 B：OpenFang 原生 FanOut（本方案）
```

---

## 五、API 调用流程

### 5.1 初始化（一次性）

```bash
# 1. 创建 10 个 processor Agent
for i in $(seq 1 10); do
  curl -X POST http://localhost:4200/api/agents \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"processor-$i\",
      \"manifest_toml\": \"...\"
    }"
done

# 2. 创建 uploader + voter Agent
curl -X POST http://localhost:4200/api/agents -d '{"name":"uploader",...}'
curl -X POST http://localhost:4200/api/agents -d '{"name":"voter",...}'

# 3. 注册 Workflow
curl -X POST http://localhost:4200/api/workflows \
  -H "Content-Type: application/json" \
  -d @workflow.json
```

### 5.2 执行（每次处理文件）

```bash
# 触发 Workflow
curl -X POST http://localhost:4200/api/workflows/{workflow_id}/run \
  -H "Content-Type: application/json" \
  -d '{"input": "path=/tmp/openfang_uploads/xxx filename=report.xlsx"}'
```

### 5.3 查看结果

```bash
# 查看 Workflow 运行状态
curl http://localhost:4200/api/workflows/{workflow_id}/runs
```

---

## 六、入口问题

当前 Agent 工具列表中没有 `workflow_run` 工具，所以 **Dashboard 聊天界面不能直接触发 Workflow**。

两种解决方式：

1. **API 触发**（不改代码）：通过 curl 或脚本调用 Workflow API
2. **加 workflow_run 工具**（改代码）：在 tool_runner.rs 加 ~30 行，让 Agent 能通过 LLM 调用触发 Workflow

如果需要 Dashboard 聊天触发，可以加一个最小工具：

```rust
// tool_runner.rs 新增
("workflow_run", "Execute a registered workflow by name or ID", |input, ctx| {
    let workflow_name = input["workflow_name"].as_str()
        .ok_or("Missing workflow_name")?;
    let wf_input = input["input"].as_str().unwrap_or("");
    // 调用 kernel.run_workflow(...)
    Ok(json!({"status": "completed", "output": result}))
})
```

---

## 七、优缺点

### 优点

- **集群能力在 OpenFang 内部**：统一管理、统一监控、统一日志
- **利用已有的 Workflow 引擎**：FanOut、Collect、变量模板都是现成的
- **不引入外部依赖**：不需要额外的 Python 容器
- **投票可追溯**：每个 StepResult 都记录了 agent_id、token 用量、耗时
- **可观测性好**：Workflow Run 有完整的状态机（Pending → Running → Completed/Failed）

### 缺点

- **需要创建 N 个 Agent 实例**：10 并发 = 12 个 Agent（10 processor + 1 uploader + 1 voter）
- **需要小改 OpenFang 源码**：FanOut 错误容忍（~6 行）
- **Dashboard 不能直接触发**：需要 API 调用或加 workflow_run 工具
- **Collect 只有拼接**：投票逻辑靠 voter Agent 的 system prompt，不如代码精确
- **LLM token 消耗大**：12 个 Agent 各自调 LLM，voter 还要分析 10 个结果

---

## 八、官方文档关键确认

> 以下内容来自 OpenFang 官方文档 `docs/workflows.md` 和 `docs/mcp-a2a.md`

### 8.1 Workflow 引擎行为

| 行为 | 文档原文 | 对本方案的影响 |
|------|----------|----------------|
| FanOut 输入一致 | "All fan-out steps receive the same `{{input}}`" | ✅ 10 个 processor 接收相同变量，用 `{{s3_url}}` 即可 |
| FanOut 失败即止 | "If any fan-out step fails or times out, the entire workflow fails immediately" | ⚠️ **必须改源码**，否则 1 个超时 = 整个 workflow 失败 |
| Collect 不执行 Agent | "It does not execute an agent -- it is a data-only step" | ✅ 不消耗 LLM token，纯拼接 |
| Collect 分隔符 | "joins all accumulated outputs with the separator `\"\\n\\n---\\n\\n\"`" | ✅ voter prompt 需要按 `---` 分割 |
| 每步独立 timeout | "Fan-out steps each get their own independent timeout" | ✅ 10 个 processor 各自 120s |
| API 同步阻塞 | "The call blocks until the workflow completes or fails" | ⚠️ curl 调用会一直等到所有 10+Agent 完成 |
| 运行记录上限 200 | MAX_RETAINED_RUNS = 200, FIFO 淘汰 | ✅ 日常使用足够 |

### 8.2 A2A 协议行为

| 行为 | 文档原文 | 对本方案的影响 |
|------|----------|----------------|
| Client 30s 超时 | "A2aClient uses a 30-second timeout" | ⚠️ 外部 manifest-agent 如果处理慢，会超时 |
| 轮询支持 | Task states: Submitted → Working → Completed | ✅ 外部 Agent 可以先返回 Working，OpenFang 再轮询 |
| Task Store 上限 1000 | max_tasks: 1000, FIFO eviction | ✅ |

### 8.3 A2A 超时问题

A2A Client 硬编码 30s 超时（`a2a.rs`），但 `a2a_send` 工具内部使用轮询：

```
1. POST /a2a/tasks/send → 获取 task_id
2. GET /a2a/tasks/{id}   → 轮询直到 Completed/Failed
```

`a2a_send` 工具本身的超时由 `timeout_secs`（step 级别，默认 120s）控制，不是 30s。
所以 **长任务不会超时**，只要在 step timeout 内完成即可。

### 8.4 三个新发现（读文档后发现）

1. **`output_var` 支持命名变量**：FanOut 的每个 step 都可以设 `output_var`，
   后续 step 用 `{{变量名}}` 引用。我们的方案里用 `{{s3_url}}` 就是这个。

2. **Conditional + Loop 可组合**：可以在 voter 之后加一个 Conditional step，
   如果投票结果包含 "LOW_CONFIDENCE"，自动重试整个 workflow（Loop 包住整个 pipeline）。

3. **CLI 也支持 Workflow**：
   ```bash
   openfang workflow create workflow.json
   openfang workflow run <id> "path=/tmp/test filename=test.xlsx"
   ```
   不一定非要 curl，CLI 命令也行。

---

## 九、验证步骤

### 8.1 前置条件

1. OpenFang 源码已做 FanOut 错误容忍改动
2. 重新编译并构建离线镜像

### 8.2 验证流程

```bash
# 1. 启动 OpenFang
docker compose up -d

# 2. 初始化
./scripts/init.sh

# 3. 验证 Agent 创建成功
curl http://localhost:4200/api/agents | python3 -m json.tool

# 4. 触发 Workflow
./scripts/run.sh "path=/tmp/test filename=test.xlsx"

# 5. 查看结果
./scripts/status.sh
```
