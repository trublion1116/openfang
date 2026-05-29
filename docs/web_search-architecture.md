# web_search 工具架构与实现机制

## 概述

`web_search` 是 OpenFang 内置的网页搜索工具，支持多搜索引擎提供商（Tavily、Brave、Perplexity、SearXNG、DuckDuckGo）自动降级，零配置即可使用。

---

## 整体调用链路

```
用户消息
  → LLM 判断需要搜索
  → 返回 tool_call: {"name": "web_search", "arguments": {"query": "..."}}
  → agent_loop.rs 解析 tool_call
  → tool_runner.rs:232 路由到 execute_tool("web_search", ...)
  → web_search.rs:45 WebSearchEngine::search(query, max_results)
  → 选择提供商 → 发 HTTP 请求 → 解析结果 → 缓存 → 返回给 LLM
```

---

## 工具注册（LLM 视角）

**文件**: `crates/openfang-runtime/src/tool_runner.rs:626-637`

LLM 看到的工具定义（Function Calling schema）：

```json
{
  "name": "web_search",
  "description": "Search the web using multiple providers (Tavily, Brave, Perplexity, DuckDuckGo) with automatic fallback. Returns structured results with titles, URLs, and snippets.",
  "input_schema": {
    "type": "object",
    "properties": {
      "query": { "type": "string", "description": "The search query" },
      "max_results": { "type": "integer", "description": "Maximum number of results to return (default: 5, max: 20)" }
    },
    "required": ["query"]
  }
}
```

---

## 工具调度

**文件**: `crates/openfang-runtime/src/tool_runner.rs:232-240`

```rust
"web_search" => {
    if let Some(ctx) = web_ctx {
        // 主路径：多提供商搜索引擎
        ctx.search.search(query, max_results).await
    } else {
        // 降级路径：裸 DuckDuckGo HTML 抓取
        tool_web_search_legacy(input).await
    }
}
```

`web_ctx`（`WebToolsContext`）在内核启动时初始化，包含搜索引擎和网页抓取引擎：

```rust
// kernel.rs:937-946
let web_ctx = WebToolsContext {
    search: WebSearchEngine::new(config.web.clone(), web_cache.clone()),
    fetch: WebFetchEngine::new(config.web.fetch.clone(), web_cache),
};
```

---

## 搜索引擎提供商

**文件**: `crates/openfang-runtime/src/web_search.rs`

### Auto 模式 fallback 链

```
Tavily → Brave → Perplexity → SearXNG → DuckDuckGo
  需key     需key     需key      需自建     零配置兜底
```

逻辑（`web_search.rs:72-112`）：

1. 检查 Tavily API key 是否存在 → 有则调用，失败则 fallback
2. 检查 Brave API key 是否存在 → 有则调用，失败则 fallback
3. 检查 Perplexity API key 是否存在 → 有则调用，失败则 fallback
4. 检查 SearXNG URL 是否配置 → 有则调用，失败则 fallback
5. DuckDuckGo 始终可用，作为最终兜底

### 各提供商原理

#### Tavily（AI Agent 原生搜索）

- **端点**: `POST https://api.tavily.com/search`
- **认证**: API Key（请求体中）
- **返回**: JSON，包含 `results[]`（title, url, content）和可选 `answer`（AI 生成摘要）
- **特点**: 专为 AI Agent 设计，搜索结果自带内容摘要，支持深度搜索模式
- **配置**:

```toml
[web]
search_provider = "tavily"

[web.tavily]
api_key_env = "TAVILY_API_KEY"
search_depth = "advanced"    # basic | advanced
include_answer = true
```

#### Brave Search

- **端点**: `GET https://api.search.brave.com/res/v1/web/search`
- **认证**: `X-Subscription-Token` 请求头
- **返回**: JSON `web.results[]`（title, url, description）
- **特点**: 支持国家、语言、时效性过滤
- **配置**:

```toml
[web]
search_provider = "brave"

[web.brave]
api_key_env = "BRAVE_API_KEY"
country = "CN"
search_lang = "zh-hans"
freshness = "pw"    # pd(天)/pw(周)/pm(月)/py(年)
```

#### Perplexity AI

- **端点**: `POST https://api.perplexity.ai/chat/completions`
- **认证**: `Authorization: Bearer <key>`
- **返回**: Chat Completions 格式，`choices[0].message.content` 为答案，`citations[]` 为来源
- **特点**: 直接用 LLM 搜索，返回自然语言答案 + 引用链接
- **配置**:

```toml
[web]
search_provider = "perplexity"

[web.perplexity]
api_key_env = "PERPLEXITY_API_KEY"
model = "sonar"
```

#### SearXNG（自建元搜索引擎）

- **端点**: `GET <自建URL>/search?format=json&q=<query>`
- **认证**: 无需
- **返回**: JSON `results[]`（url, title, content, published_date）
- **特点**: 开源自建，聚合 Google/Bing/DuckDuckGo 等多引擎结果，支持分类过滤
- **配置**:

```toml
[web]
search_provider = "searxng"

[web.searxng]
url = "http://localhost:8888"
```

#### DuckDuckGo（零配置兜底）

- **端点**: `GET https://html.duckduckgo.com/html/?q=<query>`
- **认证**: 无需
- **返回**: HTML 页面，需手动解析
- **特点**: 唯一零配置选项，不保证稳定性（中国大陆可能被墙）
- **解析逻辑**（`web_search.rs:495-540`）:

```
1. 按 class="result__a" 切割 HTML
2. 提取 href → URL（处理 uddg= 重定向参数，URL 解码）
3. 提取 >...</a> → 标题（去除 HTML 标签）
4. 提取 class="result__snippet" → 摘要
5. 组装为 (title, url, snippet) 元组列表
```

---

## 缓存层

**文件**: `crates/openfang-runtime/src/web_search.rs:47-67`

```
缓存键: "search:{query}:{max_results}"
命中 → 直接返回，不重复请求
未命中 → 执行搜索 → 成功则写入缓存
TTL: 由 config.web.cache_ttl_minutes 控制
```

---

## 超时与错误处理

| 场景 | 行为 |
|------|------|
| HTTP 请求超时 | 15 秒（`reqwest::Client::builder().timeout(15s)`） |
| 提供商返回非 200 | 返回 `Err("XXX API returned {status}")`，Auto 模式下 fallback 到下一个 |
| 解析结果为空 | 返回 `Err("No results found for '{query}'")` |
| 无 web_ctx | 降级到 `tool_web_search_legacy()`（裸 DuckDuckGo） |
| 所有提供商失败 | Agent loop 收到错误信息，LLM 自行决定下一步（如改用 web_fetch 直接抓取） |

---

## 配置参考

完整配置项（`~/.openfang/config.toml`）：

```toml
[web]
search_provider = "auto"            # auto | tavily | brave | perplexity | searxng | duckduckgo
cache_ttl_minutes = 30

[web.tavily]
api_key_env = "TAVILY_API_KEY"
search_depth = "advanced"
include_answer = true

[web.brave]
api_key_env = "BRAVE_API_KEY"
country = ""
search_lang = ""
freshness = ""

[web.perplexity]
api_key_env = "PERPLEXITY_API_KEY"
model = "sonar"

[web.searxng]
url = ""

[web.fetch]
user_agent = "Mozilla/5.0 (compatible; OpenFangAgent/0.1)"
timeout_seconds = 15
```

---

## 数据流图

```
┌──────────────────────────────────────────────────────────┐
│  LLM (GLM-5.1 / Claude / GPT)                           │
│  判断需要搜索 → tool_call: web_search(query="xxx")       │
└────────────────────────┬─────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────┐
│  tool_runner.rs  →  execute_tool("web_search", input)    │
│                                                          │
│  web_ctx 存在?                                           │
│    ├─ 是 → WebSearchEngine::search(query, max_results)   │
│    └─ 否 → tool_web_search_legacy()  (裸 DDG)           │
└────────────────────────┬─────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────┐
│  WebSearchEngine                                         │
│  provider = Auto (默认)                                  │
│                                                          │
│  ┌─────────┐  ┌───────┐  ┌────────────┐  ┌─────────┐   │
│  │ Tavily  │→│ Brave │→│ Perplexity │→│ SearXNG │   │
│  │ 需 key  │  │ 需key │  │   需 key   │  │ 需自建  │   │
│  └─────────┘  └───────┘  └────────────┘  └─────────┘   │
│                         │                                │
│                         ▼                                │
│              ┌──────────────────┐                        │
│              │   DuckDuckGo     │  ← 零配置兜底          │
│              │   抓 HTML 解析   │                         │
│              └──────────────────┘                        │
└────────────────────────┬─────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────┐
│  结果缓存 (WebCache)                                     │
│  key = "search:{query}:{max_results}"                    │
│  TTL = cache_ttl_minutes                                 │
└────────────────────────┬─────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────┐
│  返回格式化文本给 LLM                                    │
│                                                          │
│  1. 标题                                                  │
│     URL: https://...                                      │
│     摘要内容                                               │
│  2. 标题                                                  │
│     URL: https://...                                      │
│     摘要内容                                               │
└──────────────────────────────────────────────────────────┘
```

---

## 关键文件索引

| 文件 | 职责 |
|------|------|
| `crates/openfang-runtime/src/web_search.rs` | 搜索引擎主逻辑：多提供商、Auto fallback、DDG HTML 解析 |
| `crates/openfang-runtime/src/tool_runner.rs` | 工具调度：路由 web_search 调用、工具 schema 定义 |
| `crates/openfang-runtime/src/web_cache.rs` | 搜索结果缓存 |
| `crates/openfang-runtime/src/web_fetch.rs` | 网页抓取引擎（web_search 的配套工具） |
| `crates/openfang-kernel/src/kernel.rs` | 内核初始化：构建 WebToolsContext 并注入 |
| `crates/openfang-types/src/config.rs` | 配置类型定义：WebConfig、SearchProvider、各提供商配置 |

---

## 常见问题

### Q: 中国大陆 DuckDuckGo 搜索失败？

DuckDuckGo 在国内网络环境不稳定。建议配置 Tavily（有免费额度）或自建 SearXNG：

```toml
[web]
search_provider = "tavily"

[web.tavily]
api_key_env = "TAVILY_API_KEY"
```

### Q: 搜索结果质量不高？

- Tavily `search_depth = "advanced"` 可获得更深入的结果
- Brave 支持时效性过滤（`freshness = "pw"` 最近一周）
- Perplexity 返回 AI 总结 + 引用，适合研究场景

### Q: 如何减少搜索费用？

Tavily / Brave / Perplexity 都按调用计费。可以：
1. 增大 `cache_ttl_minutes` 减少重复搜索
2. 使用自建 SearXNG（完全免费）
3. DuckDuckGo 免费，但稳定性和质量有限
