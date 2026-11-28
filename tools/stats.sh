#!/bin/bash
# 看翻译神器的使用数字：每天有多少台机器检查更新（近似日活）、各版本分布、本月机器数、GitHub 下载次数。
# 用法：tools/stats.sh [天数，默认 14]
# 口径：机器数按“IP 加盐指纹”去重，同一个路由器后面的几台算一台，换网络的笔记本会算成多台；
#       1.8 及更早的版本不经过计数服务，数不到。
set -euo pipefail
cd "$(dirname "$0")/../cloudflare"
DAYS="${1:-14}"
q() {
  wrangler d1 execute fanyi-stats --remote --json --command "$1" 2>/dev/null \
    | jq -r '.[0].results | if length == 0 then "  （还没有数据）" else (.[0] | keys_unsorted | @tsv), (.[] | [.[]] | @tsv) end'
}

echo "▸ 最近 ${DAYS} 天：每天检查更新的机器数"
q "SELECT day AS 日期, COUNT(DISTINCT machine) AS 机器数, SUM(hits) AS 请求数 FROM checks WHERE day >= date('now', '+8 hours', '-${DAYS} days') GROUP BY day ORDER BY day DESC"
echo "▸ 最近 7 天：各版本的机器数"
q "SELECT version AS 版本, COUNT(DISTINCT machine) AS 机器数 FROM checks WHERE day >= date('now', '+8 hours', '-7 days') GROUP BY version ORDER BY 机器数 DESC"
echo "▸ 按月：出现过的机器数"
q "SELECT substr(day, 1, 7) AS 月份, COUNT(DISTINCT machine) AS 机器数 FROM checks GROUP BY 月份 ORDER BY 月份 DESC LIMIT 6"
echo "▸ GitHub 下载次数（含自动更新）"
gh api repos/tianyaphoto/fanyi/releases --paginate \
  -q '.[] | [.tag_name, .published_at[0:10], (.assets[0].download_count|tostring)] | @tsv'
