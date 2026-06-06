#!/usr/bin/env bash
# cleanup.sh — 清理所有 Agent 和 Workflow
set -euo pipefail

OPENFANG_API="${OPENFANG_API:-http://localhost:4200}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== 清理 FanOut 投票集群 ==="

# 删除所有 processor Agent
echo "删除 processor Agent..."
for i in $(seq 1 10); do
    id=$(curl -sf "${OPENFANG_API}/api/agents" 2>/dev/null | python3 -c "
import sys, json
agents = json.loads(sys.stdin.read())
for a in agents:
    if a.get('name') == 'processor-${i}':
        print(a['id'])
        break
" 2>/dev/null) || true
    if [ -n "$id" ]; then
        echo -n "  删除 processor-${i} ($id) ... "
        curl -sf -X DELETE "${OPENFANG_API}/api/agents/${id}" > /dev/null 2>&1 && echo "✅" || echo "❌"
    fi
done

# 删除 uploader
echo -n "删除 uploader ... "
for name in uploader voter; do
    id=$(curl -sf "${OPENFANG_API}/api/agents" 2>/dev/null | python3 -c "
import sys, json
agents = json.loads(sys.stdin.read())
for a in agents:
    if a.get('name') == '${name}':
        print(a['id'])
        break
" 2>/dev/null) || true
    if [ -n "$id" ]; then
        curl -sf -X DELETE "${OPENFANG_API}/api/agents/${id}" > /dev/null 2>&1 && echo "✅ ${name}" || echo "❌ ${name}"
    fi
done

# 删除 Workflow
WF_ID_FILE="${SCRIPT_DIR}/.workflow_id"
if [ -f "$WF_ID_FILE" ]; then
    WF_ID=$(cat "$WF_ID_FILE")
    echo -n "删除 Workflow ($WF_ID) ... "
    curl -sf -X DELETE "${OPENFANG_API}/api/workflows/${WF_ID}" > /dev/null 2>&1 && echo "✅" || echo "❌"
    rm -f "$WF_ID_FILE"
fi

echo ""
echo "=== 清理完成 ==="
