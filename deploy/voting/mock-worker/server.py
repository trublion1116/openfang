"""
Mock Worker — 模拟外部处理 Agent

实现 A2A 协议，模拟不同的处理结果用于测试投票逻辑。

行为：
  - 70% 概率返回 "正确答案 A"（模拟多数 Agent 得出相同结论）
  - 15% 概率返回 "错误答案 B"（模拟少数 Agent 出错）
  - 10% 概率返回 "错误答案 C"（模拟另一种错误）
  - 5%  概率返回随机延迟后超时（模拟网络问题）

可通过环境变量调整：
  MOCK_CORRECT_RATE=0.7    # 正确率
  MOCK_TIMEOUT_RATE=0.05   # 超时率
  MOCK_DELAY_MS=500        # 基础延迟（毫秒）
  MOCK_DELAY_JITTER=300    # 延迟抖动（毫秒）
  WORKER_PORT=9100          # 监听端口
"""

import asyncio
import json
import os
import random
import time
import uuid

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

CORRECT_RATE = float(os.environ.get("MOCK_CORRECT_RATE", "0.7"))
TIMEOUT_RATE = float(os.environ.get("MOCK_TIMEOUT_RATE", "0.05"))
DELAY_MS = int(os.environ.get("MOCK_DELAY_MS", "500"))
DELAY_JITTER = int(os.environ.get("MOCK_DELAY_JITTER", "300"))
PORT = int(os.environ.get("WORKER_PORT", "9100"))

app = FastAPI(title="Mock Worker")

AGENT_CARD = {
    "name": "mock-manifest-agent",
    "description": "模拟外部处理Agent，用于测试投票网关",
    "url": f"http://mock-worker:{PORT}/a2a",
    "version": "0.1.0",
    "capabilities": {"streaming": False, "pushNotifications": False},
    "skills": [
        {
            "id": "process-manifest",
            "name": "Manifest处理",
            "description": "模拟manifest数据处理",
        }
    ],
}


@app.get("/.well-known/agent.json")
async def agent_card():
    return AGENT_CARD


@app.get("/health")
async def health():
    return {"status": "ok", "correct_rate": CORRECT_RATE}


@app.post("/a2a")
async def handle_a2a(request: Request):
    body = await request.json()
    method = body.get("method", "")
    params = body.get("params", {})
    req_id = body.get("id", 1)

    if method == "tasks/send":
        return await handle_task(params, req_id)

    if method == "tasks/get":
        return JSONResponse({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "id": params.get("id", "unknown"),
                "status": {"state": "completed"},
            },
        })

    return JSONResponse({
        "jsonrpc": "2.0",
        "id": req_id,
        "error": {"code": -32601, "message": f"Unknown method: {method}"},
    })


async def handle_task(params: dict, req_id: int) -> JSONResponse:
    task_id = params.get("id", str(uuid.uuid4()))
    message_parts = params.get("message", {}).get("parts", [])
    user_message = " ".join(
        p.get("text", "") for p in message_parts if p.get("type") == "text"
    )

    # Simulate processing delay
    delay = (DELAY_MS + random.randint(0, DELAY_JITTER)) / 1000.0
    await asyncio.sleep(delay)

    # Simulate different outcomes
    roll = random.random()

    if roll < TIMEOUT_RATE:
        # Simulate timeout — sleep longer than typical gateway timeout
        # The gateway will handle the timeout on its side
        await asyncio.sleep(300)
        # This line likely won't be reached, but just in case
        result_text = "TIMEOUT"

    elif roll < TIMEOUT_RATE + (1 - CORRECT_RATE) * 0.5:
        result_text = "处理结果: 错误答案 B — 数据解析异常，字段缺失"

    elif roll < TIMEOUT_RATE + (1 - CORRECT_RATE):
        result_text = "处理结果: 错误答案 C — 格式不匹配，需要重新上传"

    else:
        # Correct answer (majority)
        result_text = (
            f"处理结果: 正确答案 A — 文件处理成功\n"
            f"原始请求: {user_message[:100]}\n"
            f"处理耗时: {delay*1000:.0f}ms\n"
            f"提取字段: 12个字段全部识别\n"
            f"数据完整度: 100%"
        )

    return JSONResponse({
        "jsonrpc": "2.0",
        "id": req_id,
        "result": {
            "id": task_id,
            "status": {"state": "completed"},
            "messages": [
                {
                    "role": "agent",
                    "parts": [{"type": "text", "text": result_text}],
                }
            ],
        },
    })


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=PORT)
