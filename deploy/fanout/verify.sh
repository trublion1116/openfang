#!/usr/bin/env bash
# verify.sh — 端到端验证脚本
set -euo pipefail

OPENFANG_API="${OPENFANG_API:-http://localhost:4200}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== FanOut 投票集群验证 ==="
echo ""

# 1. 检查 OpenFang 在线
echo -n "1. OpenFang API ... "
if curl -sf "${OPENFANG_API}/api/health" > /dev/null; then
    echo "✅"
else
    echo "❌ 不可达"
    exit 1
fi

# 2. 检查 Agent 数量
echo -n "2. Agent 数量 ... "
AGENT_COUNT=$(curl -sf "${OPENFANG_API}/api/agents" | python3 -c "
import sys, json
agents = json.loads(sys.stdin.read())
print(len(agents))
" 2>/dev/null || echo "0")
if [ "$AGENT_COUNT" -ge 12 ]; then
    echo "✅ ($AGENT_COUNT 个)"
else
    echo "⚠️  只有 $AGENT_COUNT 个，期望 12 个（请运行 init.sh）"
fi

# 3. 检查 Workflow 注册
echo -n "3. Workflow 注册 ... "
WF_ID_FILE="${SCRIPT_DIR}/.workflow_id"
if [ -f "$WF_ID_FILE" ]; then
    WF_ID=$(cat "$WF_ID_FILE")
    WF_CHECK=$(curl -sf "${OPENFANG_API}/api/workflows" | python3 -c "
import sys, json
wfs = json.loads(sys.stdin.read())
found = any(w.get('id') == '$WF_ID' for w in wfs)
print('yes' if found else 'no')
" 2>/dev/null || echo "no")
    if [ "$WF_CHECK" = "yes" ]; then
        echo "✅ ($WF_ID)"
    else
        echo "⚠️  workflow_id 存在但 API 查不到"
    fi
else
    echo "⚠️  未初始化（请运行 init.sh）"
fi

# 4. 检查 MCP S3 工具
echo -n "4. MCP S3 工具 ... "
TOOLS=$(curl -sf "${OPENFANG_API}/api/agents" | python3 -c "
import sys, json
agents = json.loads(sys.stdin.read())
for a in agents:
    if a.get('name') == 'uploader':
        tools = a.get('tools', [])
        has_s3 = any('s3' in str(t).lower() or 'obs' in str(t).lower() for t in tools)
        print('has_s3' if has_s3 else 'no_s3')
        break
else:
    print('no_uploader')
" 2>/dev/null || echo "error")
echo "$TOOLS"

echo ""
echo "=== 验证完成 ==="
