# Chat 消息与文件附件数据流

## 概览

用户在前端 Chat 发送带文件附件的消息时，数据经过以下完整链路：

```
前端 → WebSocket (ws.rs) → Kernel → Agent Loop → LLM → Tool Runner → MCP Server
```

---

## 1. 前端发送请求

前端通过 **WebSocket** 发送消息（不是 REST 端点）：

```json
{
  "type": "message",
  "content": "请处理 [File: document.pdf]",
  "attachments": [
    {"file_id": "uuid-xxx", "filename": "document.pdf", "content_type": "application/pdf"}
  ]
}
```

关键点：
- `[File: xxx]` 是前端自动插入的文件标记，随 `content` 文本一起发送
- `attachments` 数组包含上传文件的元数据（file_id、filename、content_type）

---

## 2. API 层路由

### 三个消息入口

| 入口 | 文件 | 函数 | 前端是否使用 |
|------|------|------|:---:|
| WebSocket | `ws.rs` | WS message handler | **是（前端默认）** |
| REST SSE | `routes.rs` | `send_message_stream` | 否 |
| REST API | `routes.rs` | `send_message` | 否 |

**前端 Chat 走的是 WebSocket 路径**（`ws.rs`），这是排查问题的关键发现。

> 排查过程：先排查了 REST `send_message` → 没日志；再排查 REST `send_message_stream` → 也没日志；最终定位到 `ws.rs` 才是实际入口。

### 三个入口共用同一套附件处理逻辑

所有入口对 hand agent 的附件处理都调用同一个公共函数 `inject_hand_attachments_into_message()`：

```rust
// routes.rs — 公共函数
pub fn inject_hand_attachments_into_message(
    message: &str,
    file_blocks: &[ContentBlock],
) -> String
```

### 调用方式（三个入口一致）

```
入口函数（ws.rs / send_message / send_message_stream）
  ├── 1. 判断是否为 hand agent
  │     hand_registry.find_by_agent(agent_id)
  │
  ├── 2. resolve_hand_attachments() 生成 FILE_ATTACHMENT 文本
  │     ├── 从 UPLOAD_REGISTRY 查找文件元数据
  │     ├── 将文件从临时目录复制到 agent workspace/uploads/
  │     └── 生成 "[FILE_ATTACHMENT] filename=... path=..." 文本 block
  │
  ├── 3. inject_hand_attachments_into_message()
  │     ├── 清理 [File: xxx]（半角/全角）
  │     └── 拼接 FILE_ATTACHMENT 文本到 message
  │
  └── 4. 调用 kernel.send_message_streaming(message, content_blocks=None)
        hand agent 的 content_blocks 始终为 None
```

### 文件路径流转

```
上传时:  浏览器 → POST /api/agents/{id}/upload → /tmp/openfang_uploads/{uuid}
处理时:  /tmp/openfang_uploads/{uuid} → {workspace}/uploads/{uuid}  (复制到沙箱可访问路径)
MCP读取: MCP server 从共享卷挂载的 {workspace}/uploads/{uuid} 读取文件
```

---

## 3. Kernel 层（kernel.rs）

```
send_message_streaming()
  ├── 配额检查 (scheduler.check_quota)
  ├── 查找 agent entry
  ├── 判断 agent 模块类型
  │     ├── "wasm:"   → execute_wasm_agent
  │     ├── "python:" → execute_python_agent
  │     └── 其他      → execute_llm_agent  ← 默认路径
  │
  └── execute_llm_agent()
        ├── 构建 system prompt（prompt_builder）
        ├── 构建 tool 列表（available_tools_with_registry）
        ├── 处理 model routing
        ├── 解析 LLM driver
        └── 调用 run_agent_loop_streaming()
```

`message` 和 `content_blocks` 透传，kernel 层不修改。

---

## 4. Agent Loop（agent_loop.rs）

```
run_agent_loop_streaming()
  ├── 1. 加载 session 历史（memory.get_session）
  ├── 2. 召回记忆（memory.recall）
  ├── 3. 构建 system prompt
  ├── 4. build_user_turn_message(user_message, content_blocks)
  │     ├── content_blocks=None → 纯文本消息 Message::user(text)
  │     └── content_blocks=Some → 多 block 消息
  │
  ├── 5. 将 user turn 加入 session
  ├── 6. 构建 LLM 请求 messages（过滤 system 消息）
  └── 7. 进入 tool-use 循环
        ├── LLM 返回文本 → 结束
        └── LLM 返回 tool_call → 执行工具 → 继续循环
```

### build_user_turn_message 构造的消息格式

**纯文本模式**（hand agent 修复后的路径）：
```json
{
  "role": "user",
  "content": "请处理\n[FILE_ATTACHMENT] filename=\"doc.pdf\" path=\"/workspace/uploads/xxx\""
}
```

**多 Block 模式**（非 hand agent，如图片附件）：
```json
{
  "role": "user",
  "content": [
    {"type": "text", "text": "请看这张图片"},
    {"type": "image", "data": "base64..."}
  ]
}
```

---

## 5. Tool Runner（tool_runner.rs）

LLM 看到 session 中的消息后，决定调用 MCP 工具：

```
tool_runner::execute_tool()
  ├── 判断 tool 类型
  │     ├── "shell_exec"     → shell 执行
  │     ├── "agent_send"     → 跨 agent 通信
  │     ├── "mcp_{server}_{tool}" → MCP 工具调用  ← 关键路径
  │     └── skill tools      → 技能执行
  │
  └── MCP 调用路径:
        ├── 解析 server_name 和 tool_name
        ├── 找到对应的 MCP 连接
        └── conn.call_tool(tool_name, input)
              input = LLM 构造的 JSON 参数
```

**关键：MCP 只看到 LLM 构造的 tool call 参数，不直接读取用户消息。**

---

## 6. MCP Server

MCP server（独立进程/容器）接收 tool call：

```json
{
  "tool_name": "upload_to_manifest",
  "arguments": {
    "file_path": "/workspace/uploads/xxx",
    "filename": "document.pdf"
  }
}
```

`arguments` 的内容完全由 LLM 从对话上下文中提取。如果 LLM 没有正确看到 `FILE_ATTACHMENT` 信息，MCP 就收不到正确的文件路径。

---

## 问题根因与修复

### 问题

```
前端通过 WebSocket (ws.rs) 发送消息
  → ws.rs 不处理 attachments（原样传递）
  → content_blocks = FILE_ATTACHMENT block，但 message 保留原始 "[File: xxx]"
  → LLM 收到多 block 模式，只关注第一个 block 的 [File:] 文本
  → LLM 构造的 MCP 参数不包含真实文件路径
  → MCP 无法找到文件
```

### 修复

提取公共函数 `inject_hand_attachments_into_message()`，三个入口统一调用：

```
任意入口（ws.rs / send_message / send_message_stream）
  → resolve_hand_attachments() 生成 file_blocks
  → inject_hand_attachments_into_message():
      ├── 清理 "[File: xxx]" 和 "【File: xxx】"
      └── 拼接 "[FILE_ATTACHMENT] filename=... path=..." 到 message_text
  → content_blocks = None（hand agent 不用 content blocks）
  → LLM 收到纯文本，包含完整 FILE_ATTACHMENT 信息
  → LLM 正确提取文件路径传给 MCP
```

### 为什么不使用 Content Block

Content Block（多 block 模式）的问题是：
- LLM 收到多个独立的 text block，可能只关注第一个
- `[FILE_ATTACHMENT]` 在第二个 block 中，容易被忽略
- 部分 LLM provider 对多 text block 的处理行为不一致

将 `FILE_ATTACHMENT` 直接拼入 message text（纯文本模式），LLM 把整段文字作为整体理解，提取信息的可靠性更高。

---

## 全部消息入口一览

排除 test 文件和 kernel 内部调用，API 层面向用户的所有消息入口：

| # | 文件 | 调用 | 场景 | Hand 附件处理 |
|---|------|------|------|:---:|
| 1 | **`ws.rs:624`** | `send_message_streaming` | **前端 Chat（WebSocket）** | 已修复 |
| 2 | `routes.rs:586` | `send_message_with_handle_and_blocks` | REST `/message` | 已修复 |
| 3 | `routes.rs:1706` | `send_message_streaming` | REST `/stream`（SSE） | 已修复 |
| 4 | `openai_compat.rs:326` | `send_message_with_handle` | OpenAI 兼容 API（非流式） | 无 |
| 5 | `openai_compat.rs:382` | `send_message_streaming` | OpenAI 兼容 API（流式） | 无 |
| 6 | `channel_bridge.rs`（4 处） | `send_message` | 外部通道（Telegram 等） | 无 |
| 7 | `routes.rs:6808` | `send_message` | 内部消息路由 | 无 |
| 8 | `routes.rs:11661` | `send_message` | 其他 API 端点 | 无 |
| 9 | `routes.rs:12493` | `send_message` | 跨 agent 消息 | 无 |

- **入口 1-3**：前端 Chat 使用的路径，已通过 `inject_hand_attachments_into_message()` 统一处理
- **入口 4-5**：OpenAI 兼容 API，调用时只传纯文本（无 attachments），暂不需要处理
- **入口 6**：外部通道（Telegram 等），通过 `send_message` 只传文本，如需支持文件附件需单独处理
- **入口 7-9**：内部/跨 agent 路径，不涉及前端文件上传场景

---

## 调试日志标记

| 标记 | 位置 | 含义 |
|------|------|------|
| `send_message: [DEBUG] raw input` | routes.rs | REST send_message 原始输入 |
| `send_message: resolving attachments` | routes.rs | REST send_message 开始处理附件 |
| `send_message_stream: resolving attachments` | routes.rs | REST SSE 开始处理附件 |
| `inject_hand_attachments_into_message: final message` | routes.rs | 公共函数的最终消息（三个入口统一） |
| `build_user_turn_message: [DEBUG]` | agent_loop.rs | 进入 session 的消息内容 |
| `MCP tool call: [DEBUG] LLM-constructed arguments` | tool_runner.rs | LLM 传给 MCP 的参数 |

---

## 代码文件索引

| 文件 | 职责 |
|------|------|
| `crates/openfang-api/src/routes.rs` | REST 端点 + 公共附件处理函数 |
| `crates/openfang-api/src/ws.rs` | WebSocket 消息处理 |
| `crates/openfang-kernel/src/kernel.rs` | Kernel 消息分发 |
| `crates/openfang-runtime/src/agent_loop.rs` | Agent 执行循环 |
| `crates/openfang-runtime/src/tool_runner.rs` | 工具执行（含 MCP 调用） |
