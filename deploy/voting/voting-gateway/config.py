"""Configuration for voting gateway."""

import os
import re


def _int(key: str, default: int) -> int:
    return int(os.environ.get(key, default))


def _str(key: str, default: str) -> str:
    return os.environ.get(key, default)


def _str_list(key: str, default: list[str]) -> list[str]:
    val = os.environ.get(key, "")
    if not val:
        return default
    return [u.strip() for u in val.split(",") if u.strip()]


# Worker
WORKER_URLS: list[str] = _str_list("WORKER_URL", ["http://mock-worker:9100/a2a"])
N_REPLICAS: int = _int("N_REPLICAS", 10)
WORKER_TIMEOUT: int = _int("WORKER_TIMEOUT", 120)

# Voting
VOTE_STRATEGY: str = _str("VOTE_STRATEGY", "exact_match")  # exact_match | majority | llm_arbitrate
MIN_SUCCESS: int = _int("MIN_SUCCESS", 3)

# LLM arbitration (only for llm_arbitrate strategy)
LLM_API_URL: str = _str("LLM_API_URL", "")
LLM_API_KEY: str = _str("LLM_API_KEY", "")
LLM_MODEL: str = _str("LLM_MODEL", "glm-5.1")

# Gateway
GATEWAY_PORT: int = _int("GATEWAY_PORT", 9200)
LOG_LEVEL: str = _str("LOG_LEVEL", "info")

# Agent card
AGENT_NAME: str = _str("AGENT_NAME", "voting-manifest-agent")
AGENT_DESCRIPTION: str = _str(
    "AGENT_DESCRIPTION",
    "并发调用多个处理Agent并投票表决，提高结果准确率",
)
