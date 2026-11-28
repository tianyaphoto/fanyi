// 把 GitHub Pages 上的更新信息原样转给 App，顺便记一笔“今天有一台机器检查了更新”。
// 只记：日期、版本号、IP 加盐后的指纹（用来去重，每月换盐）。不存 IP，不含任何翻译内容。
// 这里出任何问题 App 都会改去 GitHub Pages 直接取（见 Sources/Updater.swift），不影响更新。
const UPSTREAM = 'https://tianyaphoto.github.io/fanyi/appcast.xml';

export async function onRequestGet({ request, env, waitUntil }) {
  const upstream = await fetch(UPSTREAM, { cf: { cacheTtl: 300, cacheEverything: true } });
  if (!upstream.ok) return new Response('upstream error', { status: 502 });
  waitUntil(record(request, env).catch(() => {}));
  return new Response(upstream.body, {
    headers: { 'content-type': 'application/xml; charset=utf-8', 'cache-control': 'no-store' },
  });
}

async function record(request, env) {
  // 只数 App 自己发的请求（带版本号），爬虫和浏览器不算。
  const version = new URL(request.url).searchParams.get('v') || '';
  if (!/^\d+(\.\d+){0,3}$/.test(version) || !env.DB) return;
  const day = new Date(Date.now() + 8 * 3600 * 1000).toISOString().slice(0, 10);
  const machine = await fingerprint(request.headers.get('cf-connecting-ip') || '', day.slice(0, 7), env.SALT);
  await env.DB.prepare(
    `INSERT INTO checks (day, machine, version) VALUES (?, ?, ?)
     ON CONFLICT (day, machine, version) DO UPDATE SET hits = hits + 1`
  ).bind(day, machine, version).run();
}

// 没配 SALT 时不做指纹（否则公开代码 + 无盐的哈希能反推出 IP），只能数请求次数。
async function fingerprint(ip, month, salt) {
  if (!salt || !ip) return 'unknown';
  const bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`${month}|${ip}|${salt}`));
  return [...new Uint8Array(bytes)].slice(0, 8).map((b) => b.toString(16).padStart(2, '0')).join('');
}
