-- 收口 public.works 的 INSERT,并修掉一个会导致数据损坏的既有缺陷
-- =====================================================================
-- 目标:让"先审后发"在结构上成立。在此之前它做不到 ——
--   works_insert_own 允许 authenticated 直接 INSERT public.works
--   (lib/community/publish_service.dart 就是这么写的),所以客户端的任何
--   校验都是可绕过的软限制,直接调 Supabase REST API 即可塞入任意内容。
--
-- ⚠️ 20260818050000 收口的是 **storage.objects(文件桶)**,不是 works **表**。
--    两扇门名字很像,那次只关了一扇。这次关另一扇。
--
-- 依赖:20260429020000(建表/策略)、20260817000000(moderation 列)、
--       20260817011000(moderation 守卫)、20260818010000(策略改用
--       app.current_user_id())、20260818030000(kill switch)


-- ── 1. 修既有缺陷:works 没有任何唯一约束 ────────────────────────────
-- 这不是收口带来的问题,是现在就在的 bug:
--   · 上传路径是内容寻址 '{uid}/{sha1}.ply'(publish_service.dart)
--   · staging 上传用 upsert:true
--   · works 表上没有 unique
--   ⇒ 同一用户重发同一份 PLY:finalize 走 already 分支,客户端继续 INSERT
--     **第二行**,两行共用一个 storage 对象。
--   ⇒ 之后 delete-work 会 remove 那个共用对象,于是删掉其中一件作品,
--     另一件当场变成指向不存在文件的死行。
--
-- 2026-08-23 已在生产库确认 duplicate_pairs = 0,可直接建索引。
create unique index if not exists uq_works_user_model_path
  on public.works (user_id, model_storage_path)
  where model_storage_path is not null;

comment on index public.uq_works_user_model_path is
  '内容寻址路径的幂等键。upload-finalize 靠它把重试收敛成同一行(23505 后回读)。';


-- ── 2. kill switch 的 public 包装 ───────────────────────────────────
-- 收口后 INSERT 由 service_role 执行,而 service_role **绕过 RLS** ⇒
-- kill_switch_works_write(RESTRICTIVE, for insert to authenticated)对新路径
-- 完全不生效。运营关掉 'uploads' 开关将不再能阻止作品创建 —— 等于把已有的
-- 刹车拆了。补偿办法是让 Edge Function 显式查开关并 fail-closed。
--
-- 但 app.switch_on 位于 app schema,PostgREST 默认只暴露 public ⇒ 边缘函数
-- 调不到。这里加一个 public 包装,只授给 service_role(开关状态不必让客户端看见)。
create or replace function public.uploads_enabled()
returns boolean
language sql
stable
security definer
set search_path = app, public
as $$ select app.switch_on('uploads') $$;

revoke all on function public.uploads_enabled() from public, anon, authenticated;
grant execute on function public.uploads_enabled() to service_role;


-- ── 3. 撤销客户端对 works 表的 INSERT ───────────────────────────────
-- 三层,缺一层都留口子:
--   (a) 撤 PERMISSIVE 策略 —— 没有 PERMISSIVE 允许即为拒绝
--   (b) 加 RESTRICTIVE 守卫 —— 即便日后有人重新创建 works_insert_own 之类
--       的 PERMISSIVE 策略(看起来完全无害的操作),这条仍会一律否决。
--       被撤销的策略是**看不见的**,几个月后没人记得这里曾经有过一条;
--       用 RESTRICTIVE 把意图固化,让重新开门必须是显式的。
--       (这段论证照抄 20260818050000,那次针对 storage.objects。)
--   (c) revoke 表级 GRANT —— 2026-08-23 实测 anon/authenticated 持有
--       works 的全部表级权限(Supabase 默认,靠 RLS 控制)。RLS 是唯一防线,
--       再收一层纵深。
drop policy if exists works_insert_own on public.works;

create policy works_no_client_insert on public.works
  as restrictive
  for insert to anon, authenticated
  with check (false);

revoke insert on public.works from anon, authenticated;


-- ── 4. 列级 UPDATE 守卫 ─────────────────────────────────────────────
-- 🔴 只收口 INSERT 是装饰品。works_update_own 的判据只有归属,**允许更新任意
--    列**,而两个 moderation 守卫只保护 moderation_status 与 deleted_at。
--    所以作者可以:用干净标题发布 → 过审 → UPDATE 成任意内容;
--    或以 private 发布绕过审核 → 再把 visibility 翻成 'public'
--    (works_select_visible 只看 visibility/moderation_status/deleted_at,
--     不看文本审没审过)。
--
-- ⚠️ 不能整条撤 works_update_own:community_service.dart 的缩略图回填依赖
--    作者的 UPDATE 权限。所以走列级守卫,**thumbnail_storage_path 不在保护
--    列表里**,那条链路不受影响。
--
-- ⚠️ 必须是 SECURITY INVOKER(即不写 security definer)。写成 DEFINER 的话
--    current_user 会变成函数属主,下面的角色判断永远不成立,守卫静默失效。
--    20260817011000 的注释里有这条陷阱的原文记载。
create or replace function public.guard_work_content_columns()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if (new.title is distinct from old.title
      or new.description is distinct from old.description
      or new.visibility is distinct from old.visibility
      or new.published_at is distinct from old.published_at
      or new.model_storage_path is distinct from old.model_storage_path
      or new.file_size_bytes is distinct from old.file_size_bytes
      or new.format is distinct from old.format
      or new.user_id is distinct from old.user_id)
     and current_user in ('anon', 'authenticated') then  -- [PORTABLE]
    raise exception 'work content fields are managed by the upload-finalize function'
      using errcode = '42501';  -- insufficient_privilege
  end if;
  return new;
end;
$$;

drop trigger if exists guard_work_content_columns on public.works;
create trigger guard_work_content_columns
  before update on public.works
  for each row execute function public.guard_work_content_columns();


-- ── 5. 让作者能删掉自己"从未公开过的待审作品" ───────────────────────
-- 🔴 这一条是硬约束级别的:20260817011000 的 guard_work_moderation_delete 写着
--      if (old.moderation_status is distinct from 'ok' or old.deleted_at is not null)
--         and current_user in ('anon','authenticated') then raise
--    "先审后发"要求新作品以 moderation_status='under_review' 落库,于是
--    **作者在审核期间无法删除自己的作品** —— 直接违反 Apple App Store
--    Guideline 1.2 要求的"用户可移除自己的内容"。
--
-- 例外只开给"从未公开过的待审作品"(published_at is null):
--   · 它从未对任何人可见,删掉不影响任何取证需要;
--   · 已被 removed 的、或曾经公开过的,仍然删不掉 —— 那才是该防的规避行为。
create or replace function public.guard_work_moderation_delete()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if (old.moderation_status is distinct from 'ok' or old.deleted_at is not null)
     and current_user in ('anon', 'authenticated')  -- [PORTABLE]
     and not (old.moderation_status = 'under_review' and old.published_at is null)
  then
    raise exception 'moderated works cannot be deleted'
      using errcode = '42501';
  end if;
  return old;
end;
$$;
