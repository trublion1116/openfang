#!/bin/bash
# stop.sh — 停止投票集群
set -e
cd "$(dirname "$0")/.."
docker compose down
echo "投票集群已停止"
