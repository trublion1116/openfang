#!/bin/bash
# start.sh — 一键启动投票集群
set -e

cd "$(dirname "$0")/.."

# 检查 .env
if [ ! -f .env ]; then
    echo "错误：未找到 .env 文件"
    echo "请先执行：cp .env.example .env && vim .env"
    exit 1
fi

# 检查必要镜像
echo "检查镜像..."
for img in "openfang:0.6.4-offline-manifest-v12" "mcp-obs-s3:1.2.0"; do
    if ! docker image inspect "$img" >/dev/null 2>&1; then
        echo "警告：镜像 $img 未找到"
        echo "请先加载镜像：docker load < xxx.tar.gz"
    fi
done

echo ""
echo "启动投票集群..."
docker compose up -d --build

echo ""
echo "等待服务就绪..."
sleep 5

# 等待 OpenFang 健康
for i in $(seq 1 30); do
    if curl -sf http://localhost:4200/api/health >/dev/null 2>&1; then
        echo "OpenFang 就绪 ✓"
        break
    fi
    echo "  等待 OpenFang... ($i/30)"
    sleep 2
done

# 等待投票网关健康
for i in $(seq 1 15); do
    if curl -sf http://localhost:9200/health >/dev/null 2>&1; then
        echo "投票网关就绪 ✓"
        break
    fi
    echo "  等待投票网关... ($i/15)"
    sleep 2
done

echo ""
echo "========================================="
echo " 投票集群已启动"
echo "========================================="
echo ""
echo " Dashboard:  http://localhost:4200"
echo " 投票网关:   http://localhost:9200"
echo " 投票网关管理: http://localhost:9200/config"
echo " 投票统计:    http://localhost:9200/stats"
echo ""
echo " 运行验证: ./scripts/verify.sh"
echo ""
