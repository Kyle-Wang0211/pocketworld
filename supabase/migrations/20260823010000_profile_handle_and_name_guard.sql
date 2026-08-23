-- 昵称双轨制:可重复的 display_name + 唯一的 handle,并收口二者的写入口
-- =====================================================================
-- 产品决定(2026-08-23,用户拍板):照抄 Discord / 微信的双轨制。
--   display_name  可重复、中文/emoji 放行、走 RFC 8266 PRECIS Nickname Profile
--   handle        唯一、纯小写 ASCII(a-z 0-9 . _)、走 Discord 收窄口径
--
-- 为什么不给 display_name 加唯一约束(这是被业界证据推翻的原始需求):
--   · Discord 2023-05-03 公告原文:唯一的是 username,display name
--     "can include just about anything… change whenever you want";
--     他们做唯一 handle 的公开理由是"找得到人"(原文:almost half of all
--     friend requests fail / 40%+ 用户不记得自己的 discriminator),
--     **不是**为了防重名。
--   · 微信/QQ/抖音/小红书同样是"昵称可重复 + 唯一 ID";微博是唯一的例外,
--     且把唯一性做成了付费点。
--   · 婚庆场景大量同姓同名("张三""伴娘""新娘的妈妈"),强制唯一会当场误伤。
--   · 技术上,NFKC+toLower+空格折叠做唯一键会产生用户无法理解的碰撞
--     ("张三" vs "张 三"),而 emoji 变体选择符(U+FE0F)又让唯一约束形同虚设
--     (视觉相同的两个心形能同时注册)。唯一性放在 ASCII handle 上,这些全没了。
--
-- 依赖:20260429020000_core_business.sql(profiles 建表)
--       20260510000000_sync_display_name_on_update.sql(本迁移删除其触发器)

-- ── 1. 新列 ───────────────────────────────────────────────────────────
-- handle 允许 NULL:存量用户没有 handle,不能强制。首次设置由 Edge Function 完成。
-- handle_key 是唯一键。当前规则下它恒等于 handle(规范化后已是小写 ASCII),
-- 但仍单独存一列 —— 将来若放宽字符集,存储值与比较值就会分叉,那时改规则
-- 不必再动索引定义。这是 RFC 8266 §2.3/§2.4 "enforcement 与 comparison 是
-- 两个不同的串"那条分层的同款处理。
alter table public.profiles
  add column if not exists handle text
    check (handle is null or handle ~ '^[a-z0-9._]{2,32}$'),
  add column if not exists handle_key text,
  add column if not exists display_name_changed_at timestamptz,
  add column if not exists handle_changed_at timestamptz;

-- 部分唯一索引:允许任意多行 handle_key IS NULL(存量用户),
-- 但非空值必须全局唯一。
create unique index if not exists uq_profiles_handle_key
  on public.profiles (handle_key)
  where handle_key is not null;

comment on column public.profiles.handle is
  '唯一标识,小写 ASCII a-z/0-9/./_,长度 2-32(Discord 口径)。可为 NULL=尚未设置。';
comment on column public.profiles.handle_key is
  '用于唯一约束的比较键。当前恒等于 handle;放宽字符集时才会与 handle 分叉。';

-- ── 2. display_name 的 DB 硬上限:防滥用,不是产品上限 ──────────────────
-- 产品上限是 20 个**字素簇**(UAX #29),由 Edge Function 用 Intl.Segmenter 强制
-- —— Postgres 没有字素簇计数函数,char_length 数的是码点。
-- 二者口径不同:一个 ZWJ 家庭 emoji 是 1 个字素簇但 8 个码点,所以 20 字素簇
-- 最坏情况约 160 码点。原有的 char_length<=50 会先于产品规则炸掉,
-- 且报的是 23514 而不是可读提示。这里放宽到 200 纯粹防 zalgo/超长滥用,
-- 真正的产品上限在应用层。
do $$
declare
  -- ⚠️ 变量名不能叫 conname:PL/pgSQL 里它会与 pg_constraint.conname 这个列名
  --    冲突,报 "column reference conname is ambiguous"。加 v_ 前缀避开。
  v_conname text;
begin
  -- ⚠️ 必须是 pg_get_constraintdef(c.oid) 而不是 pg_get_constraintdef(c):
  --    该函数签名接受 oid,传整行记录会报 42883 function does not exist。
  --    (2026-08-23 首次 push 就是栽在这里,整个文件事务回滚。)
  select c.conname into v_conname
  from pg_constraint c
  where c.conrelid = 'public.profiles'::regclass
    and c.contype = 'c'
    and pg_get_constraintdef(c.oid) like '%display_name%';
  if v_conname is not null then
    execute format('alter table public.profiles drop constraint %I', v_conname);
    raise notice '[profile_handle] dropped old display_name check: %', v_conname;
  end if;
end $$;

alter table public.profiles
  add constraint profiles_display_name_len
  check (char_length(display_name) between 1 and 200);

-- ── 3. 拆掉 auth.users -> profiles 的自动同步暗道 ─────────────────────
-- 20260510000000 装了一个 AFTER UPDATE ON auth.users 的 SECURITY DEFINER
-- 触发器,把 raw_user_meta_data->>'display_name' 同步进 profiles。
--
-- 它是本次收口必须拆掉的那条路,原因有两层:
--   (a) auth.updateUser() 修改自己的 user_metadata 是 Supabase Auth 的**内置
--       能力**,RLS 关不掉。所以只要这个触发器还在,任何客户端都能绕过
--       Edge Function 的全部校验(长度/保留词/审核/冷却),把任意字符串
--       送进 profiles.display_name —— 而 feed 展示的正是这一列。
--   (b) 它还有一条 fallback:coalesce(..., split_part(new.email,'@',1))。
--       注册一个 '管理员@example.com' 的邮箱,昵称就自动变成"管理员",
--       全程零校验。这直接违反第八条的禁止假冒。
--
-- 拆掉之后,display_name 的唯一写入口是 Edge Function(service_role)。
-- 原触发器注释里担心的"web build / admin tools 不走 mirror 会失同步"
-- 不再成立:那些客户端同样必须调 Edge Function,没有第二条路。
drop trigger if exists on_auth_user_metadata_updated on auth.users;
drop function if exists public.handle_user_display_name_update();

-- ── 4. 列级守卫:身份列只许 service_role 改 ────────────────────────────
-- 不撤 profiles_update_self 整条策略 —— 用户仍应能改 avatar_url / banner_url /
-- location / website / is_private 等自己的资料。只把**账号信息**那几列锁住,
-- 照抄 20260817011000 的 guard_work_moderation_columns 模式。
-- 锁定范围对齐第二十三条对"账号信息"的定义(名称/头像/封面/简介/签名/认证信息)
-- 中本产品实际开放的部分:display_name、handle、bio。头像与封面冷启动不开放
-- 上传入口,一旦开放需要把 avatar_url / banner_url 一并纳入本守卫并接图片审核。
--
-- ⚠️ 必须是 SECURITY INVOKER(即不写 security definer)。写成 DEFINER 的话
--    current_user 会变成函数属主,下面的角色判断永远不成立,守卫静默失效。
--    这条陷阱在 20260817011000 的注释里有原文记载,不要重蹈。
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
      or new.handle_changed_at is distinct from old.handle_changed_at)
     and current_user in ('anon', 'authenticated') then  -- [PORTABLE]
    raise exception 'display_name / handle / bio are managed by the set-profile-name function'
      using errcode = '42501';  -- insufficient_privilege
  end if;
  return new;
end;
$$;

drop trigger if exists guard_profile_identity_columns on public.profiles;
create trigger guard_profile_identity_columns
  before update on public.profiles
  for each row execute function public.guard_profile_identity_columns();

-- ⚠️ 注册路径:profiles 行由 20260429030000 的 on_auth_user_created 触发器
--    (SECURITY DEFINER)创建,走的是 INSERT 而非 UPDATE,不受本守卫影响。
--    首次设置 handle 仍走 Edge Function 的 UPDATE(service_role,同样不受影响)。

-- ── 5. bio 也是"账号信息",一并纳入守卫并放宽 DB 硬顶 ─────────────────
-- 《互联网用户账号信息管理规定》第二十三条把账号信息定义为"名称、头像、封面、
-- **简介**、签名、认证信息等",bio 就是其中的"简介" ⇒ 第十条的核验义务同样覆盖它。
-- 原先只锁 display_name/handle 是个缺口:bio 有 1000 字,是本产品剩下的最大一块
-- 自由文本,却能被客户端直接 UPDATE。
--
-- 产品上限是 160 个**字素簇**,取 Twitter/X 的 bio 口径(Instagram 是 150,
-- 二者构成 150-160 的业界共识区间;取宽松的那个)。与 display_name 同样的分层:
-- 字素簇计数只能在应用层做(Postgres 没有该函数),DB 这一条纯粹防滥用。
-- 原有的 char_length<=1000 在最坏情况下会先炸:160 字素簇若全是 ZWJ emoji
-- 约 1280 码点,会撞上 1000 报 23514 而不是给出可读提示。放宽到 2000。
do $$
declare
  -- ⚠️ 变量名不能叫 conname:PL/pgSQL 里它会与 pg_constraint.conname 这个列名
  --    冲突,报 "column reference conname is ambiguous"。加 v_ 前缀避开。
  v_conname text;
begin
  -- ⚠️ 必须是 pg_get_constraintdef(c.oid) 而不是 pg_get_constraintdef(c):
  --    该函数签名接受 oid,传整行记录会报 42883 function does not exist。
  --    (2026-08-23 首次 push 就是栽在这里,整个文件事务回滚。)
  select c.conname into v_conname
  from pg_constraint c
  where c.conrelid = 'public.profiles'::regclass
    and c.contype = 'c'
    and pg_get_constraintdef(c.oid) like '%bio%';
  if v_conname is not null then
    execute format('alter table public.profiles drop constraint %I', v_conname);
    raise notice '[profile_handle] dropped old bio check: %', v_conname;
  end if;
end $$;

alter table public.profiles
  add constraint profiles_bio_len
  check (bio is null or char_length(bio) <= 2000);

-- ── 6. 存量回填 ───────────────────────────────────────────────────────
-- 不自动生成 handle。理由:handle 是面向用户的标识,自动分配会产生一批
-- 用户不认识、也不好看的 ID(GitHub 的教训是旧名释放后被抢注冒充)。
-- 让用户在 App 内首次设置,未设置前 handle 为 NULL、不参与唯一约束。
