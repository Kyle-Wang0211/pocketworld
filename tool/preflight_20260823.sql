-- ============================================================================
-- Pre-flight:apply 2026-08-23 这两个迁移之前必须先看的东西
--
--   20260823000000_tighten_description_length.sql   works.description -> 30 字
--   20260823010000_profile_handle_and_name_guard.sql 昵称双轨制 + 收口
--
-- 用法:整份粘进 Supabase SQL Editor 跑一次,逐条对照下面的"判读"。
--      全部只读,不改任何数据。
-- ============================================================================


-- ── [1] 会被**截断**的 description ──────────────────────────────────────────
-- 判读:rows_to_truncate = 0 ⇒ 可以直接 apply。
--      > 0 ⇒ 迁移会把这些行的 description 截到 30 字(有损!)。
--      产品尚未上线,预期这里是 0 或只有测试数据。不是 0 就先看清楚是谁的。
select
  count(*)                       as rows_to_truncate,
  coalesce(max(char_length(description)), 0) as longest_now
from public.works
where char_length(description) > 30;

-- 真要看是哪几条:
-- select id, user_id, left(description, 60) || '…' as head, char_length(description)
-- from public.works where char_length(description) > 30 order by 4 desc limit 20;


-- ── [2] profiles 的现有 CHECK 约束 ─────────────────────────────────────────
-- 判读:20260823010000 用 DO 块按 `pg_get_constraintdef LIKE '%display_name%'`
--      和 '%bio%' 去找并 drop 旧约束。这里确认它们确实存在且只有一条,
--      否则 DO 块会漏删(它用的是 select ... into,多条只取一条)。
select conname, pg_get_constraintdef(oid) as def
from pg_constraint
where conrelid = 'public.profiles'::regclass and contype = 'c'
order by conname;


-- ── [3] 迁移的幂等性:新列/新索引是否已经存在 ────────────────────────────
-- 判读:全空 ⇒ 首次 apply,正常。
--      已有 ⇒ 说明迁移跑过一次,再跑是安全的(全部 IF NOT EXISTS)。
select column_name
from information_schema.columns
where table_schema = 'public' and table_name = 'profiles'
  and column_name in ('handle', 'handle_key',
                      'display_name_changed_at', 'handle_changed_at');

select indexname from pg_indexes
where schemaname = 'public' and tablename = 'profiles'
  and indexname = 'uq_profiles_handle_key';


-- ── [4] 那条要拆掉的自动同步暗道是否还在 ────────────────────────────────
-- 判读:返回 1 行 ⇒ 触发器还在,迁移会删掉它(这正是收口的关键一步)。
--      返回 0 行 ⇒ 已经没有了,迁移的 DROP 是 no-op,安全。
select tgname
from pg_trigger
where tgrelid = 'auth.users'::regclass
  and tgname = 'on_auth_user_metadata_updated'
  and not tgisinternal;


-- ── [5] 存量 display_name 里有没有会被新规则拒掉的 ─────────────────────
-- 迁移**不会**追溯校验存量,所以这里只是让你心里有数:
-- 这些用户下次改名时会被 set-profile-name 挡下来。
-- 判读:数字大不影响 apply,但说明保留词表可能过宽,值得看几条样本。
select count(*) as existing_names_hitting_reserved_terms
from public.profiles
where display_name ~ '(官方|客服|管理员|系统通知|小助手|中国|中华|中央|全国|国家)'
   or lower(display_name) ~ '(admin|official|support|staff|system|root)';


-- ============================================================================
-- 以下三条属于**另一条线**(works INSERT 收口进 upload-finalize),
-- 那条线还没动手,但这三个答案决定它怎么写。顺手一起取了。
-- ============================================================================

-- ── [6] works 的 RLS 策略实况 ──────────────────────────────────────────────
-- 为什么必须查:20260818010000 是**运行时 DO 块**,把全库策略里的 auth.uid()
-- 改写成 app.current_user_id()。迁移文件读不出线上最终形态,也不排除有人
-- 在 Studio 里手工加过策略。
-- 判读:关注 polpermissive(f = RESTRICTIVE)与表达式里到底是 auth.uid()
--      还是 app.current_user_id() —— 新迁移必须跟现状一致,否则同一张表
--      会出现两套判据。
select
  polname,
  polpermissive,
  polcmd,
  pg_get_expr(polqual, polrelid)      as using_expr,
  pg_get_expr(polwithcheck, polrelid) as check_expr
from pg_policy
where polrelid = 'public.works'::regclass
order by polname;


-- ── [7] works 有没有重复行(决定 unique index 能不能直接加)────────────────
-- 背景:storage 路径是内容寻址 '{uid}/{sha1}.ply',而 works 表上**没有任何
-- unique 约束**。同一份 PLY 重发会产生两行共用一个 storage 对象;之后
-- delete-work 删掉那个对象,另一行当场变成指向不存在文件的死行。
-- 判读:0 ⇒ `create unique index on works (user_id, model_storage_path)`
--         可以直接加。
--      > 0 ⇒ 必须先合并/清理,否则建索引会失败。
select count(*) as duplicate_pairs
from (
  select user_id, model_storage_path
  from public.works
  where model_storage_path is not null
  group by 1, 2
  having count(*) > 1
) t;


-- ── [8] authenticated 在**表级 GRANT** 上还有没有 INSERT ──────────────────
-- RLS 之外还有一层:即便撤了 works_insert_own 策略、加了 RESTRICTIVE 守卫,
-- 如果表级 GRANT 还给着 INSERT,那 RESTRICTIVE(false) 就是唯一防线。
-- 判读:若列出 INSERT,收口时一并 `revoke insert on public.works from authenticated`。
select grantee, privilege_type
from information_schema.role_table_grants
where table_schema = 'public' and table_name = 'works'
  and grantee in ('anon', 'authenticated')
order by grantee, privilege_type;
