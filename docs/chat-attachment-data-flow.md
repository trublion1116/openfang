# Chat 消息与文件附件数据流

## 概览

用户在前端 Chat 发送带文件附件的消息时，数据经过以下完整链路：

```
前端 → API 层 → Kernel → Agent Loop → LLM → Tool Runner → MCP Server
```

---

## 1. 前端发送请求

前端通过 SSE streaming 端点发送消息（**不是** REST `/message` 端点）：

```
POST /api/agents/{id}/stream
Body: {
  "message": "请处理 [File: document.pdf]",
  "attachments": [{ "file_id": "uuid-xxx", "filename": "document.pdf", "content_type": "application/pdf" }],
  "sender_id": "user-1",
  "sender_name": "admin"
}
```

关键点：
- `[File: xxx]` 是前端自动插入的文件标记，随 `message` 文本一起发送
- `attachments` 数组包含上传文件的元数据（file_id、filename、content_type）

---

## 2. API 层路由（routes.rs）

### 两个入口

| 端点 | 函数 | 前端是否使用 |
|------|------|:---:|
| `POST /api/agents/{id}/stream` | `send_message_stream` | 是（前端默认） |
| `POST /api/agents/{id}/message` | `send_message` | 否 |

**前端走的是 streaming 路径**，这是排查问题的关键发现。

### Hand Agent 附件处理（streaming 端点）

```
send_message_stream()
  ├── 1. 判断是否为 hand agent
  │     hand_registry.find_by_agent(agent_id)
  │
  ├── 2. resolve_hand_attachments() 生成 FILE_ATTACHMENT 文本
  │     ├── 从 UPLOAD_REGISTRY 查找文件元数据
  │     ├── 将文件从临时目录复制到 agent workspace/uploads/
  │     └── 生成 "[FILE_ATTACHMENT] filename=... path=..." 文本
  │
  ├── 3. 清理 message_text 中的 [File: xxx]
  │     ├── 去掉半角 [File: ...]
  │     └── 去掉全角 【File: ...】
  │
  ├── 4. 将 FILE_ATTACHMENT 拼接到 message_text
  │     "请处理\n[FILE_ATTACHMENT] filename=\"doc.pdf\" path=\"/workspace/uploads/uuid\""
  │
  └── 5. 调用 kernel.send_message_streaming(message_text, content_blocks=None)
```

对于 hand agent，`content_blocks` 传 `None`，所有信息都在 `message_text` 里。
对于普通 agent，走 `resolve_attachments()` 生成 base64 图片 block。

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
  │           [Text("用户消息"), Text("[FILE_ATTACHMENT]...")]
  │
  ├── 5. 将 user turn 加入 session
  ├── 6. 构建 LLM 请求 messages（过滤 system 消息）
  └── 7. 进入 tool-use 循环
        ├── LLM 返回文本 → 结束
        └── LLM 返回 tool_call → 执行工具 → 继续循环
```

### build_user_turn_message 构造的消息格式

**纯文本模式**（修复后 hand agent 的路径）：
```json
{
  "role": "user",
  "content": "请处理\n[FILE_ATTACHMENT] filename=\"doc.pdf\" path=\"/workspace/uploads/xxx\""
}
```

**多 Block 模式**（修复前的路径，非 hand agent 仍使用）：
```json
{
  "role": "user",
  "content": [
    {"type": "text", "text": "[File: document.pdf] 请处理"},
    {"type": "text", "text": "[FILE_ATTACHMENT] filename=\"doc.pdf\" path=\"/workspace/uploads/xxx\""}
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
前端走 streaming 端点
  → send_message_stream 不处理 attachments
  → content_blocks = None
  → message_text 保留原始 "[File: xxx]"
  → LLM 只看到 "[File: xxx]"
  → LLM 构造的 MCP 参数不包含真实文件路径
  → MCP 无法找到文件
```

### 修复（v8）

```
前端走 streaming 端点
  → send_message_stream 处理 hand attachments
  → 清理 "[File: xxx]"，拼接 "[FILE_ATTACHMENT] filename=... path=..."
  → content_blocks = None，全部在 message_text 中
  → LLM 看到完整的 FILE_ATTACHMENT 信息
  → LLM 正确提取文件路径传给 MCP
  → MCP 成功处理文件
```

### 为什么不使用 Content Block

Content Block（多 block 模式）的问题是：
- LLM 收到多个独立的 text block，可能只关注第一个
- `[FILE_ATTACHMENT]` 在第二个 block 中，容易被忽略
- 部分 LLM provider 对多 text block 的处理行为不一致

将 `FILE_ATTACHMENT` 直接拼入 message text（纯文本模式），LLM 把整段文字作为整体理解，提取信息的可靠性更高。

---

## 调试日志标记

| 标记 | 位置 | 含义 |
|------|------|------|
| `send_message: [DEBUG] raw input` | routes.rs | 原始消息和附件数 |
| `send_message_stream: resolving attachments` | routes.rs | streaming 路径开始处理附件 |
| `send_message_stream: hand attachment blocks generated` | routes.rs | 生成了几个 FILE_ATTACHMENT block |
| `send_message: [DEBUG] stripped [File:...]` | routes.rs | [File:xxx] 清理前后对比 |
| `send_message: [DEBUG] message with FILE_ATTACHMENT appended` | routes.rs | 最终拼好的消息 |
| `send_message: [DEBUG] FINAL state before kernel dispatch` | routes.rs | 传给 kernel 前的最终状态 |
| `build_user_turn_message: [DEBUG]` | agent_loop.rs | 进入 session 的消息内容 |
| `MCP tool call: [DEBUG] LLM-constructed arguments` | tool_runner.rs | LLM 传给 MCP 的参数 |
