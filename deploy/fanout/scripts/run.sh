#!/usr/bin/env bash
# run.sh — 触发 FanOut 投票 Workflow
set -euo pipefail

OPENFANG_API="${OPENFANG_API:-http://localhost:4200}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WF_ID_FILE="${SCRIPT_DIR}/.workflow_id"

if [ ! -f "$WF_ID_FILE" ]; then
    echo "❌ 未找到 workflow_id，请先运行 ./init.sh"
    exit 1
fi

WF_ID=$(cat "$WF_ID_FILE")
INPUT="${1:-}"

if [ -z "$INPUT" ]; then
    echo "用法: ./run.sh '<input text>'"
    echo "示例: ./run.sh 'path=/tmp/openfang_uploads/xxx filename=report.xlsx'"
    exit 1
fi

echo "触发 Workflow: $WF_ID"
echo "输入: $INPUT"
echo ""

RESP=$(curl -sf -X POST "${OPENFANG_API}/api/workflows/${WF_ID}/run" \
    -H "Content-Type: application/json" \
    -d "{\"input\": $(echo "$INPUT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))')}" 2>&1) || {
    echo "❌ 触发失败"
    echo "$RESP"
    exit 1
}

echo "$RESP" | python3 -m json.tool 2>/dev/null || echo "$RESP"
