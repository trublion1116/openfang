"""
Voting Gateway — A2A 协议兼容的投票网关

对外：实现 A2A 协议 (/.well-known/agent.json + POST /a2a)
对内：并发调用 N 个外部 Worker → 收集结果 → 投票表决 → 返回

投票策略：
  - exact_match: 精确匹配，计数最多者胜出（适合结构化输出）
  - majority:    精确匹配 + 要求超过半数（适合分类/选择题）
  - llm_arbitrate: 用 LLM 分析多个结果，综合判断（适合开放式问答）
"""

import asyncio
import json
import logging
import time
import uuid
from collections import Counter
from typing import Any

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

import config

logging.basicConfig(
    level=getattr(logging, config.LOG_LEVEL.upper(), logging.INFO),
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("voting-gateway")

app = FastAPI(title="Voting Gateway")

# ── Stats ──────────────────────────────────────────────────────────
stats: dict[str, Any] = {
    "total_requests": 0,
    "total_success": 0,
    "total_failed": 0,
    "total_worker_calls": 0,
    "total_worker_success": 0,
    "total_worker_timeout": 0,
    "total_worker_error": 0,
}


# ── A2A Agent Card ────────────────────────────────────────────────
AGENT_CARD: dict[str, Any] = {
    "name": config.AGENT_NAME,
    "description": config.AGENT_DESCRIPTION,
    "url": f"http://voting-gateway:{config.GATEWAY_PORT}/a2a",
    "version": "0.1.0",
    "capabilities": {"streaming": False, "pushNotifications": False},
    "skills": [
        {
            "id": "process-and-vote",
            "name": "并发处理投票",
            "description": "并发调用N个Worker并投票表决，提高结果准确率",
        }
    ],
}


@app.get("/.well-known/agent.json")
async def agent_card():
    return AGENT_CARD


# ── Health / Config / Stats ───────────────────────────────────────
@app.get("/health")
async def health():
    return {
        "status": "ok",
        "n_replicas": config.N_REPLICAS,
        "vote_strategy": config.VOTE_STRATEGY,
        "worker_urls": config.WORKER_URLS,
    }


@app.get("/config")
async def show_config():
    return {
        "worker_urls": config.WORKER_URLS,
        "n_replicas": config.N_REPLICAS,
        "vote_strategy": config.VOTE_STRATEGY,
        "worker_timeout": config.WORKER_TIMEOUT,
        "min_success": config.MIN_SUCCESS,
        "llm_model": config.LLM_MODEL if config.VOTE_STRATEGY == "llm_arbitrate" else None,
    }


@app.get("/stats")
async def show_stats():
    return stats


# ── Worker call ───────────────────────────────────────────────────
async def call_worker(
    client: httpx.AsyncClient,
    url: str,
    message: str,
    replica_index: int,
) -> dict[str, Any]:
    """Call a single worker via A2A protocol. Returns {success, result, error, duration_ms}."""
    start = time.monotonic()
    try:
        resp = await client.post(
            url,
            json={
                "jsonrpc": "2.0",
                "id": replica_index,
                "method": "tasks/send",
                "params": {
                    "message": {
                        "role": "user",
                        "parts": [{"type": "text", "text": message}],
                    }
                },
            },
            timeout=float(config.WORKER_TIMEOUT),
        )
        duration_ms = int((time.monotonic() - start) * 1000)
        body = resp.json()

        if resp.status_code >= 400:
            stats["total_worker_error"] += 1
            return {
                "success": False,
                "error": f"HTTP {resp.status_code}: {body}",
                "replica": replica_index,
                "duration_ms": duration_ms,
            }

        # Extract text from A2A response
        result = body.get("result", {})
        messages = result.get("messages", [])
        text = ""
        if messages:
            parts = messages[-1].get("parts", [])
            text = " ".join(p.get("text", "") for p in parts if p.get("type") == "text")

        status_state = result.get("status", {})
        if isinstance(status_state, dict):
            state = status_state.get("state", "unknown")
        else:
            state = str(status_state)

        stats["total_worker_success"] += 1
        return {
            "success": state == "completed",
            "result": text,
            "state": state,
            "replica": replica_index,
            "duration_ms": duration_ms,
        }

    except httpx.TimeoutException:
        duration_ms = int((time.monotonic() - start) * 1000)
        stats["total_worker_timeout"] += 1
        return {
            "success": False,
            "error": f"Timeout after {config.WORKER_TIMEOUT}s",
            "replica": replica_index,
            "duration_ms": duration_ms,
        }
    except Exception as e:
        duration_ms = int((time.monotonic() - start) * 1000)
        stats["total_worker_error"] += 1
        return {
            "success": False,
            "error": str(e),
            "replica": replica_index,
            "duration_ms": duration_ms,
        }


# ── Voting strategies ─────────────────────────────────────────────
def vote_exact_match(results: list[str]) -> dict[str, Any]:
    """精确匹配投票：完全相同的答案计数，最多者胜出。"""
    counter = Counter(results)
    best_answer, best_count = counter.most_common(1)[0]
    confidence = best_count / len(results) if results else 0
    distribution = counter.most_common()

    return {
        "answer": best_answer,
        "confidence": confidence,
        "winning_count": best_count,
        "total": len(results),
        "distribution": [(ans, cnt) for ans, cnt in distribution],
    }


def vote_majority(results: list[str]) -> dict[str, Any]:
    """多数投票：要求超过半数才通过，否则返回 inconclusive。"""
    counter = Counter(results)
    best_answer, best_count = counter.most_common(1)[0]
    confidence = best_count / len(results) if results else 0

    if best_count > len(results) / 2:
        return {
            "answer": best_answer,
            "confidence": confidence,
            "winning_count": best_count,
            "total": len(results),
            "distribution": [(ans, cnt) for ans, cnt in counter.most_common()],
        }
    else:
        return {
            "answer": "INCONCLUSIVE — 没有任何答案获得超过半数票",
            "confidence": confidence,
            "winning_count": best_count,
            "total": len(results),
            "distribution": [(ans, cnt) for ans, cnt in counter.most_common()],
        }


async def vote_llm_arbitrate(results: list[str], original_message: str) -> dict[str, Any]:
    """LLM 仲裁投票：将所有结果交给 LLM 分析，综合判断。"""
    if not config.LLM_API_URL or not config.LLM_API_KEY:
        # Fallback to exact_match if LLM not configured
        log.warning("LLM arbitration requested but LLM_API_URL/LLM_API_KEY not set, falling back to exact_match")
        return vote_exact_match(results)

    prompt = f"原始请求：{original_message}\n\n"
    prompt += f"以下是 {len(results)} 个独立 Agent 的处理结果：\n\n"
    for i, r in enumerate(results, 1):
        prompt += f"--- Agent {i} ---\n{r}\n\n"
    prompt += """请分析以上所有结果，综合判断后给出最终答案。
要求：
1. 找出各 Agent 结果中的共识点和分歧点
2. 对每个关键结论统计支持数量
3. 给出你认为最可靠的最终答案
4. 说明你的判断理由

输出格式：
最终答案：<你的答案>
置信度：<高/中/低>
分析：<简要说明为什么选择这个答案>
"""

    try:
        async with httpx.AsyncClient(timeout=120) as client:
            resp = await client.post(
                config.LLM_API_URL,
                headers={
                    "Authorization": f"Bearer {config.LLM_API_KEY}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": config.LLM_MODEL,
                    "messages": [{"role": "user", "content": prompt}],
                    "temperature": 0.1,
                    "max_tokens": 4096,
                },
            )
            body = resp.json()
            answer = body["choices"][0]["message"]["content"]
            return {
                "answer": answer,
                "confidence": None,
                "winning_count": None,
                "total": len(results),
                "distribution": None,
                "method": "llm_arbitrate",
            }
    except Exception as e:
        log.error(f"LLM arbitration failed: {e}, falling back to exact_match")
        return vote_exact_match(results)


# ── A2A endpoint ──────────────────────────────────────────────────
@app.post("/a2a")
async def handle_a2a(request: Request):
    body = await request.json()
    method = body.get("method", "")
    params = body.get("params", {})
    req_id = body.get("id", 1)

    # tasks/send — main processing
    if method == "tasks/send":
        return await handle_task_send(body, params, req_id)

    # tasks/get — poll status (we complete synchronously, so always completed)
    if method == "tasks/get":
        task_id = params.get("id", "unknown")
        return JSONResponse({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "id": task_id,
                "status": {"state": "completed"},
                "messages": [{"role": "agent", "parts": [{"type": "text", "text": "Task already completed"}]}],
            },
        })

    return JSONResponse({
        "jsonrpc": "2.0",
        "id": req_id,
        "error": {"code": -32601, "message": f"Unknown method: {method}"},
    })


async def handle_task_send(body: dict, params: dict, req_id: int) -> JSONResponse:
    task_id = params.get("id", str(uuid.uuid4()))
    message_parts = params.get("message", {}).get("parts", [])
    user_message = " ".join(
        p.get("text", "") for p in message_parts if p.get("type") == "text"
    )

    log.info(f"Task {task_id}: received message ({len(user_message)} chars)")

    stats["total_requests"] += 1
    start_time = time.monotonic()

    # ── Fan out: call N workers concurrently ──
    n = config.N_REPLICAS
    worker_urls = config.WORKER_URLS

    async with httpx.AsyncClient() as client:
        tasks = []
        for i in range(n):
            url = worker_urls[i % len(worker_urls)]  # round-robin if multiple URLs
            tasks.append(call_worker(client, url, user_message, i + 1))
            stats["total_worker_calls"] += 1

        log.info(f"Task {task_id}: fanning out to {n} workers")
        worker_results = await asyncio.gather(*tasks)

    # ── Separate success/failure ──
    successes = [r for r in worker_results if r.get("success")]
    failures = [r for r in worker_results if not r.get("success")]

    log.info(
        f"Task {task_id}: {len(successes)}/{n} workers succeeded, "
        f"{len(failures)} failed"
    )

    # ── Check minimum success threshold ──
    if len(successes) < config.MIN_SUCCESS:
        stats["total_failed"] += 1
        error_detail = "\n".join(
            f"  Worker-{r['replica']}: {r.get('error', 'unknown')}" for r in failures
        )
        reply = (
            f"投票失败：仅 {len(successes)}/{n} 个 Worker 成功 "
            f"（需要至少 {config.MIN_SUCCESS} 个）\n\n"
            f"失败详情：\n{error_detail}"
        )
    else:
        # ── Vote ──
        result_texts = [r["result"] for r in successes]

        if config.VOTE_STRATEGY == "majority":
            vote_result = vote_majority(result_texts)
        elif config.VOTE_STRATEGY == "llm_arbitrate":
            vote_result = await vote_llm_arbitrate(result_texts, user_message)
        else:  # exact_match (default)
            vote_result = vote_exact_match(result_texts)

        stats["total_success"] += 1

        # Build reply
        confidence_str = (
            f"{vote_result['confidence']:.0%}"
            if vote_result.get("confidence") is not None
            else "LLM仲裁"
        )
        reply = f"投票结果 ({len(successes)}/{n} 成功, 置信度 {confidence_str}):\n\n"
        reply += vote_result["answer"]

        # Append details
        reply += f"\n\n--- 投票详情 ---\n"
        reply += f"策略: {config.VOTE_STRATEGY}\n"
        reply += f"并发数: {n}\n"
        reply += f"成功: {len(successes)}, 失败: {len(failures)}\n"

        if vote_result.get("distribution"):
            reply += "\n投票分布:\n"
            for ans, cnt in vote_result["distribution"]:
                preview = ans[:80].replace("\n", " ") + ("..." if len(ans) > 80 else "")
                reply += f"  [{cnt}票] {preview}\n"

        if failures:
            reply += "\n失败Worker:\n"
            for f_r in failures:
                reply += f"  Worker-{f_r['replica']}: {f_r.get('error', 'unknown')}\n"

    duration_ms = int((time.monotonic() - start_time) * 1000)
    log.info(f"Task {task_id}: completed in {duration_ms}ms")

    return JSONResponse({
        "jsonrpc": "2.0",
        "id": req_id,
        "result": {
            "id": task_id,
            "status": {"state": "completed"},
            "messages": [
                {
                    "role": "agent",
                    "parts": [{"type": "text", "text": reply}],
                }
            ],
        },
    })


# ── Main ──────────────────────────────────────────────────────────
if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=config.GATEWAY_PORT)
