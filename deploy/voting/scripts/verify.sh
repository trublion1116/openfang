#!/bin/bash
# verify.sh — 投票集群自动化验证脚本
#
# 用法: ./scripts/verify.sh
#
# 验证项：
#   1. 所有容器运行中
#   2. OpenFang 健康检查
#   3. Mock Worker A2A 协议
#   4. 投票网关 A2A 协议
#   5. 投票网关直接调用（绕过 OpenFang）
#   6. 投票统计

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass=0
fail=0

check() {
    local desc="$1"
    local cmd="$2"
    local expect="$3"

    result=$(eval "$cmd" 2>&1) || true
    if echo "$result" | grep -q "$expect"; then
        echo -e "  ${GREEN}✓${NC} $desc"
        ((pass++))
    else
        echo -e "  ${RED}✗${NC} $desc"
        echo -e "    期望包含: $expect"
        echo -e "    实际输出: $(echo "$result" | head -3)"
        ((fail++))
    fi
}

echo "========================================"
echo " 投票集群验证"
echo "========================================"
echo ""

# ── 1. 容器状态 ──
echo "1. 容器状态"
for svc in openfang-voting mcp-obs-s3-voting voting-gateway mock-worker; do
    check "$svc 运行中" \
        "docker ps --filter name=$svc --format '{{.Status}}'" \
        "Up"
done
echo ""

# ── 2. OpenFang 健康检查 ──
echo "2. OpenFang 健康检查"
check "OpenFang /api/health" \
    "curl -sf http://localhost:4200/api/health" \
    "ok"
echo ""

# ── 3. Mock Worker ──
echo "3. Mock Worker A2A 协议"
check "Mock Worker Agent Card" \
    "curl -sf http://localhost:9200/.well-known/agent.json || curl -sf http://mock-worker:9100/.well-known/agent.json 2>/dev/null || echo 'skip'" \
    "mock"

# Direct call to mock worker (from host via port exposure, or from gateway)
check "Mock Worker /health" \
    "docker exec voting-gateway curl -sf http://mock-worker:9100/health 2>/dev/null || echo 'needs-network'" \
    "ok"
echo ""

# ── 4. 投票网关 ──
echo "4. 投票网关"
check "投票网关 /health" \
    "curl -sf http://localhost:9200/health" \
    "ok"

check "投票网关 Agent Card" \
    "curl -sf http://localhost:9200/.well-known/agent.json" \
    "voting"

check "投票网关 /config" \
    "curl -sf http://localhost:9200/config" \
    "n_replicas"
echo ""

# ── 5. 投票网关直接调用（核心测试）──
echo "5. 投票网关直接调用 (×3 次)"

for i in 1 2 3; do
    check "投票测试 #$i" \
        "curl -sf -X POST http://localhost:9200/a2a \
          -H 'Content-Type: application/json' \
          -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tasks/send\",\"params\":{\"message\":{\"role\":\"user\",\"parts\":[{\"type\":\"text\",\"text\":\"Process file at S3 URL: https://test.obs.example.com/test.xlsx\"}]}}}'" \
        "投票结果"
done
echo ""

# ── 6. 投票统计 ──
echo "6. 投票统计"
check "统计端点有数据" \
    "curl -sf http://localhost:9200/stats" \
    "total_requests"
echo ""

# ── 结果汇总 ──
echo "========================================"
echo -e " 结果: ${GREEN}$pass 通过${NC}, ${RED}$fail 失败${NC}"
echo "========================================"

if [ $fail -gt 0 ]; then
    echo ""
    echo "排查建议："
    echo "  docker compose logs voting-gateway  # 查看投票网关日志"
    echo "  docker compose logs mock-worker     # 查看 Mock Worker 日志"
    echo "  docker compose logs openfang         # 查看 OpenFang 日志"
    exit 1
fi

echo ""
echo "全部通过！可以进行下一步测试："
echo "  1. 浏览器打开 http://localhost:4200"
echo "  2. 在 Hands 页面激活 Manifest Pipeline Hand"
echo "  3. 上传一个文件，观察投票结果"
echo ""
echo "手动测试投票网关（不经过 OpenFang）："
echo "  curl -X POST http://localhost:9200/a2a \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tasks/send\",\"params\":{\"message\":{\"role\":\"user\",\"parts\":[{\"type\":\"text\",\"text\":\"Process file at S3 URL: https://test.obs.xxx/test.xlsx\"}]}}}'"
