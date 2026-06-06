#!/usr/bin/env bash
# status.sh — 查看 Workflow 运行状态
set -euo pipefail

OPENFANG_API="${OPENFANG_API:-http://localhost:4200}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WF_ID_FILE="${SCRIPT_DIR}/.workflow_id"

if [ ! -f "$WF_ID_FILE" ]; then
    echo "❌ 未找到 workflow_id，请先运行 ./init.sh"
    exit 1
fi

WF_ID=$(cat "$WF_ID_FILE")

echo "=== Workflow 运行记录 ==="
echo "Workflow ID: $WF_ID"
echo ""

curl -sf "${OPENFANG_API}/api/workflows/${WF_ID}/runs" | python3 -c "
import sys, json
runs = json.loads(sys.stdin.read())
if not runs:
    print('  (无运行记录)')
    sys.exit(0)

for r in runs:
    state = r.get('state', '?')
    icon = {'completed': '✅', 'failed': '❌', 'running': '⏳'}.get(state, '❓')
    print(f'{icon} {r[\"id\"][:8]}...  state={state}  started={r.get(\"started_at\",\"?\")}')
    
    steps = r.get('step_results', [])
    if steps:
        print(f'   Steps ({len(steps)}):')
        for s in steps:
            agent = s.get('agent_name', '?')
            name = s.get('step_name', '?')
            ms = s.get('duration_ms', 0)
            out_preview = s.get('output', '')[:80].replace(chr(10), ' ')
            print(f'     - {name} ({agent}) {ms}ms → {out_preview}...')
    print()
" 2>/dev/null || echo "❌ 查询失败"

echo ""
echo "查看所有 Agent:"
curl -sf "${OPENFANG_API}/api/agents" | python3 -c "
import sys, json
agents = json.loads(sys.stdin.read())
for a in agents:
    name = a.get('name', '?')
    aid = a.get('id', '?')[:8]
    print(f'  {name}  (id={aid}...)')
" 2>/dev/null || echo "❌ 查询失败"
