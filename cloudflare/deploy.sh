#!/bin/bash
# 部署计数服务。拷到临时目录再部署：在某些目录结构下 wrangler 读不到本目录配置里的 D1 绑定（见 README「坑」）。
set -euo pipefail
cd "$(dirname "$0")"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cp -R functions public wrangler.jsonc "$TMP/"
cd "$TMP"
wrangler pages deploy --branch main --commit-dirty=true
