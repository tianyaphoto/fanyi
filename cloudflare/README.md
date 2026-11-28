# 更新检查计数

App 每天检查一次更新。检查请求先到 `https://fanyi-updates.pages.dev/appcast.xml?v=版本号`（Cloudflare Pages 函数），
函数把 GitHub Pages 上的 `docs/appcast.xml` 原样返回，并在 D1 数据库 `fanyi-stats` 里记一行：日期、版本号、IP 加盐指纹。
取不到时 App 自动改去 GitHub Pages 直接取，所以这个服务挂了也不影响更新。发版流程不变，不用重新部署这里。

- 看数字：`tools/stats.sh`
- 部署：`cloudflare/deploy.sh`（拷到临时目录再部署，原因见下面「坑」）
- 第一次搭建：`wrangler d1 create fanyi-stats`（把 database_id 填进 wrangler.jsonc）→
  `wrangler d1 execute fanyi-stats --remote --file schema.sql` → `wrangler pages secret put SALT`（随便一串随机字符，不进仓库）→ 部署
- 本机试：`wrangler pages dev --d1 DB=fanyi-stats`，另开终端 `curl 'localhost:8788/appcast.xml?v=1.9'`，再用 sqlite3 看 `.wrangler/state/v3/d1/` 下的库

## 坑

- 在作者机器上，直接在本目录跑 `wrangler pages dev` 读不到配置里的 D1 绑定（上级目录有别的 package.json，拷到别处就正常），函数拿不到 `env.DB` 时不报错、只是不记数。所以部署走 `deploy.sh`，部署后一定用真实请求验一次：`curl 'https://fanyi-updates.pages.dev/appcast.xml?v=0.0'` 后 `tools/stats.sh` 里应多一行。
- Sparkle 取不到更新信息时报的错误码是 2001（downloadError），不是 1002；回退检查必须在 `didFinishUpdateCycleFor` 回调里当场发起，晚一拍会被当成“检查进行中”忽略。
