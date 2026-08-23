-- IP 属地(第十二条)—— 数据结构 + 解析函数
-- =====================================================================
-- 法条依据:《互联网用户账号信息管理规定》(网信办令第10号)第十二条
--   "互联网信息服务提供者应当在互联网用户账号信息页面展示合理范围内的
--    互联网用户账号的互联网协议(IP)地址归属地信息。"
--
-- ⚠️ 正式稿写的是"合理范围内",**没有**像 2021 征求意见稿那样明文写死
--    "境内标注到省(区、市)、境外标注到国家(地区)"。所以粒度是平台自定的,
--    但全行业(微博/抖音/小红书/B站/知乎)在 2022 年统一落在了征求意见稿
--    那个粒度上。我们照抄该粒度 —— 不自创,也不比同行更细(更细 = 无谓的
--    隐私暴露,《个人信息保护法》第六条"最小必要")。
--
-- 数据源:ip2region(github.com/lionsoul2014/ip2region)
--   · 许可 Apache-2.0,可商用
--   · data/ipv4_source.txt 每行 7 段:
--       起始IP|结束IP|国家|省份|城市|ISP|ISO国家码
--     例:  1.0.1.0|1.0.3.255|中国|福建省|福州市|中国电信|CN
--          1.0.0.0|1.0.0.255|Australia|Queensland|0|0|AU
--   · 🔑 港澳台在该库里 ISO 码就是 **CN**,省份分别是
--     香港特别行政区/澳门特别行政区/台湾省 —— 与我们要展示的口径一致,
--     不需要任何特殊处理。
--   · 境外行的国家名是**英文**,所以中文国家名由导入脚本用 CLDR
--     (Intl.DisplayNames zh-CN)按 ISO 码生成,不手写 240 条对照表。
--
-- 归一化(展示串)在**导入时**算好写进 region 列,查询期零加工:
--   CN  → 省份短称:福建省→福建、北京市→北京、香港特别行政区→香港
--   其他 → 中文国家名:AU→澳大利亚
--   未知/保留段 → NULL(前端不展示该行,而不是展示"未知")


-- ── 1. 区间表 ────────────────────────────────────────────────────────
-- 用 inet 而不是 bigint:inet 同时装得下 IPv4 与 IPv6,而 IPv6 用
-- bigint 根本存不下(128 位)。中国移动网络 IPv6 占比已经很高,
-- 只做 IPv4 等于对一大批真实用户显示不出属地。
--
-- PostgreSQL 的 inet btree 排序**先比 family**,所以 v4 与 v6 的区间
-- 在索引里天然分区,永不交错 —— 下面那条"倒序取第一条"的查法对两族
-- 都成立,不需要分表。
create table if not exists public.ip_region_ranges (
  ip_start inet primary key,
  ip_end   inet not null,
  region   text,
  constraint ip_region_ranges_ordered check (ip_start <= ip_end)
);

comment on table public.ip_region_ranges is
  'ip2region(Apache-2.0)导入的 IP→属地区间表。区间互不重叠且已排序,'
  '由 tool/import_ip2region.mjs 全量重建。region 是已归一化的展示串。';

-- 🔴 RLS 开着、且**一条策略都不建** = 除 service_role 外任何人都读不到。
-- 这张表不需要给客户端读:属地已经落在 works.publish_region /
-- profiles.last_region 上了。放开它等于白送一份 IP 库,也扩大了
-- "拿别人的属地反查 IP 段"的面。
alter table public.ip_region_ranges enable row level security;


-- ── 2. 解析函数 ──────────────────────────────────────────────────────
-- SECURITY DEFINER:调用方(service_role 走 Edge Function)要能读上面那张
-- RLS 全关的表。search_path='' + 全限定名,防 search_path 劫持
-- —— 与 20260823030000 对 uploads_enabled 做的收口同一条规矩。
create or replace function public.resolve_ip_region(p_ip text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ip     inet;
  v_end    inet;
  v_region text;
begin
  if p_ip is null or btrim(p_ip) = '' then
    return null;
  end if;

  -- 🔴 必须 try/catch:p_ip 来自 x-forwarded-for,是**外部可控**的字符串。
  -- 直接 cast 会在畸形输入上抛 22P02 把整个调用打成 500。
  -- 拿不到属地不是错误,是"不展示"。
  begin
    v_ip := p_ip::inet;
  exception when others then
    return null;
  end;

  -- 内网/回环没有属地可言,短路(也省一次索引扫描)。
  -- 本地开发与内部转发都会命中这一支。
  if v_ip <<= '127.0.0.0/8'::inet
     or v_ip <<= '10.0.0.0/8'::inet
     or v_ip <<= '172.16.0.0/12'::inet
     or v_ip <<= '192.168.0.0/16'::inet
     or v_ip <<= '169.254.0.0/16'::inet
     or v_ip <<= '::1/128'::inet
     or v_ip <<= 'fc00::/7'::inet
     or v_ip <<= 'fe80::/10'::inet then
    return null;
  end if;

  -- 区间互不重叠且已排序 ⇒ "起点 ≤ 目标"的**最后一条**是唯一候选。
  -- 走 PK 的反向索引扫描,读一行就停,O(log n)。
  --
  -- 🔴 终点的判断必须放在**函数里**,不能写进上面这条 SQL 的 WHERE。
  --    写成 `ip_start <= v AND ip_end >= v ORDER BY ip_start DESC LIMIT 1`,
  --    当 IP 落在两个区间的空隙里时,ip_end 只是个 filter —— 扫描会一路
  --    反向走遍**所有**更小的区间去找一个不存在的匹配,退化成 O(n)。
  --    (区间表查找的经典陷阱;GiST 是给可重叠区间的,这里区间不重叠。)
  select r.ip_end, r.region into v_end, v_region
  from public.ip_region_ranges r
  where r.ip_start <= v_ip
    and family(r.ip_start) = family(v_ip)
  order by r.ip_start desc
  limit 1;

  if v_end is null or v_end < v_ip then
    return null;   -- 落在空隙里
  end if;
  return v_region;
end;
$$;

comment on function public.resolve_ip_region(text) is
  'IP 字符串 → 属地展示串(第十二条)。畸形输入/内网/查不到一律返回 NULL。';

-- 只有服务端能调。客户端能调 = 把这张表变成一个可任意查询的 IP 库。
revoke all on function public.resolve_ip_region(text) from public;
revoke all on function public.resolve_ip_region(text) from anon, authenticated;
grant execute on function public.resolve_ip_region(text) to service_role;


-- ── 3. 落点列 ────────────────────────────────────────────────────────
-- works.publish_region:**发布那一刻**的属地,写死不再变。
--   同行(微博/抖音)在内容上展示的就是发布时属地,不是作者当前属地。
--   历史内容的属地不该因为作者今天出差而改变。
alter table public.works
  add column if not exists publish_region text;

comment on column public.works.publish_region is
  '发布时的 IP 属地(第十二条)。由 upload-finalize 写入,此后不再变更。'
  'NULL = 未解析出(内网/IP 库未覆盖/IP 库尚未导入),前端不展示。';

-- profiles.last_region:账号信息页面展示的属地,随最近一次活跃更新。
alter table public.profiles
  add column if not exists last_region text,
  add column if not exists last_region_at timestamptz;

comment on column public.profiles.last_region is
  '账号信息页面展示的 IP 属地(第十二条)。由 report-region Edge Function 更新。';

-- 🔴 这两列是**服务端事实**,和 display_name/handle 一样绝不能让客户端自己写
-- (客户端可写 = 属地可伪造 = 这个展示失去全部意义,也就等于没做第十二条)。
-- 20260823010000 已经建了 guard_profile_identity_columns 这个 BEFORE UPDATE
-- 触发器来守 display_name/handle,这里把两列并进去,不新建触发器。
-- ⚠️ 下面是 20260823010000 那个函数的**原样重贴 + 两列**。
--    它用的是 current_user in ('anon','authenticated') 这个 [PORTABLE] 判据
--    (不是 JWT claim,也不是 SECURITY DEFINER)—— 照抄,不要"顺手改进":
--    service_role 与 SECURITY DEFINER 触发器的 current_user 都不在那两个值里,
--    所以服务端路径天然放行,这是它现在能工作的原因。
create or replace function public.guard_profile_identity_columns()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if (new.display_name is distinct from old.display_name
      or new.handle is distinct from old.handle
      or new.handle_key is distinct from old.handle_key
      or new.bio is distinct from old.bio
      or new.display_name_changed_at is distinct from old.display_name_changed_at
      or new.handle_changed_at is distinct from old.handle_changed_at
      -- [IP-REGION 2026-08-24] 属地是**服务端事实**。客户端可写 = 属地可伪造
      -- = 第十二条这个展示失去全部意义,等于没做。
      or new.last_region is distinct from old.last_region
      or new.last_region_at is distinct from old.last_region_at)
     and current_user in ('anon', 'authenticated') then  -- [PORTABLE]
    raise exception 'display_name / handle / bio / last_region are managed by Edge Functions'
      using errcode = '42501';  -- insufficient_privilege
  end if;
  return new;
end;
$$;
-- 触发器本身 20260823010000 已建,函数体替换即生效,不需要重建触发器。
