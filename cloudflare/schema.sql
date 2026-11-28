-- 每台机器每天每个版本一行。machine 是 IP 加盐后的指纹（每月换盐，跨月对不上），不存 IP 本身。
CREATE TABLE IF NOT EXISTS checks (
  day     TEXT NOT NULL,            -- 北京时间日期 2026-11-27
  machine TEXT NOT NULL,
  version TEXT NOT NULL,            -- App 版本号，如 1.9
  hits    INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (day, machine, version)
);
