#!/usr/bin/env bash
# init.sh — 初始化 FanOut 投票集群
# 创建 12 个 Agent + 注册 1 个 Workflow
set -euo pipefail

OPENFANG_API="${OPENFANG_API:-http://localhost:4200}"
N_PROCESSORS="${N_PROCESSORS:-10}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== OpenFang FanOut 投票集群初始化 ==="
echo "API: $OPENFANG_API"
echo "Processor 数量: $N_PROCESSORS"
echo ""

# 检查 OpenFang 是否在线
if ! curl -sf "${OPENFANG_API}/api/health" > /dev/null 2>&1; then
    echo "❌ OpenFang API 不可达: ${OPENFANG_API}"
    echo "   请先启动 OpenFang: docker compose up -d"
    exit 1
fi
echo "✅ OpenFang API 在线"

# ─── 创建 Agent 的函数 ────────────────────────────────────
create_agent_from_toml() {
    local name="$1"
    local toml_path="$2"

    if [ ! -f "$toml_path" ]; then
        echo "❌ 找不到配置: $toml_path"
        return 1
    fi

    local toml_content
    toml_content=$(cat "$toml_path")

    echo -n "  创建 Agent '$name' ... "
    local resp
    resp=$(curl -sf -X POST "${OPENFANG_API}/api/agents" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"${name}\",
            \"manifest_toml\": $(echo "$toml_content" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
        }" 2>&1) || {
        echo "❌ 失败"
        echo "   $resp"
        return 1
    }

    local agent_id
    agent_id=$(echo "$resp" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('agent_id','?'))" 2>/dev/null || echo "?")
    echo "✅ id=$agent_id"
}

# ─── Step 1: 创建 uploader Agent ──────────────────────────
echo ""
echo "--- 创建 uploader Agent ---"
create_agent_from_toml "uploader" "${SCRIPT_DIR}/agents/uploader/agent.toml"

# ─── Step 2: 创建 processor-1..N Agent ────────────────────
echo ""
echo "--- 创建 processor Agent (×${N_PROCESSORS}) ---"
PROCESSOR_TEMPLATE="${SCRIPT_DIR}/agents/processor/agent.toml"

# 创建临时目录
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

for i in $(seq 1 "$N_PROCESSORS"); do
    # 从模板生成，替换 {NAME} 占位符
    local_toml="${TMPDIR}/processor-${i}.toml"
    sed "s/{NAME}/processor-${i}/g" "$PROCESSOR_TEMPLATE" > "$local_toml"
    create_agent_from_toml "processor-${i}" "$local_toml"
done

# ─── Step 3: 创建 voter Agent ──────────────────────────────
echo ""
echo "--- 创建 voter Agent ---"
create_agent_from_toml "voter" "${SCRIPT_DIR}/agents/voter/agent.toml"

# ─── Step 4: 注册 Workflow ─────────────────────────────────
echo ""
echo "--- 注册 Workflow ---"
WORKFLOW_FILE="${SCRIPT_DIR}/workflow.json"

if [ ! -f "$WORKFLOW_FILE" ]; then
    echo "❌ 找不到 workflow.json"
    exit 1
fi

echo -n "  注册 fanout-voting-pipeline ... "
WF_RESP=$(curl -sf -X POST "${OPENFANG_API}/api/workflows" \
    -H "Content-Type: application/json" \
    -d @"$WORKFLOW_FILE" 2>&1) || {
    echo "❌ 失败"
    echo "   $WF_RESP"
    exit 1
}

WF_ID=$(echo "$WF_RESP" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('workflow_id','?'))" 2>/dev/null || echo "?")
echo "✅ workflow_id=$WF_ID"

# 保存 workflow_id 供后续脚本使用
echo "$WF_ID" > "${SCRIPT_DIR}/.workflow_id"

echo ""
echo "=== 初始化完成 ==="
echo "  Agent 总数: $((N_PROCESSORS + 2))"
echo "  Workflow ID: $WF_ID"
echo ""
echo "下一步:"
echo "  ./scripts/run.sh 'path=/tmp/test filename=test.xlsx'"
echo "  ./scripts/status.sh"
