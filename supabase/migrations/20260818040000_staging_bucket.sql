-- 两阶段上传:staging 私有桶
-- =====================================================================
-- 目标不变量:**客户端只被授权写一个永不公开的私有桶;公开桶的写权限
-- 只有服务端持有**。
--
-- 为什么必须是物理隔离,而不是"标记未校验 + 策略拒读":
--   AWS 有更省事的做法 —— 给对象打扫描状态标签,桶策略 Deny 掉未标记为
--   干净的 GetObject(TBAC),零字节移动、URL 不变。**这条路在 Supabase 上
--   结构性不通**,三重原因:
--     ① 公开桶的读**完全绕过 RLS**(官方原话:公开桶 "effectively bypasses
--        access controls for both retrieving and serving files"),CDN 直连,
--        没有任何策略引擎介入的机会;
--     ② Supabase 没有对象标签概念,唯一沾边的 user_metadata 是**上传时由
--        客户端在 x-metadata 头里带的**,攻击者可控,不能当门禁依据;
--     ③ 改用私有桶 + 条件读,就放弃了"公开 URL 直连 CDN"这个前提。
--   ⇒ 物理搬移是必需的,不是可选优化。
--
-- 为什么这比客户端校验强:
--   它把"校验是否发生"与"内容能否被公开访问"拆成由**不同主体**控制的两件
--   事。客户端能决定的只有"要不要调 finalize";它决定不了字节落在哪个桶
--   —— 路径是被签进上传 token 的。跳过 finalize 的后果是对象**静静躺在
--   私有桶里,永远拿不到公开 URL**。而攻击者的目的正是公开,所以跳过校验
--   的收益为零。
--
-- move 的成本:Supabase 的"桶"不是真的 S3 桶,而是同一个 S3 桶里的 key
-- 前缀,所以跨桶 move = S3 服务端 CopyObject + delete,**字节从不离开 S3,
-- 不计入 egress**。

-- ── staging 桶 ────────────────────────────────────────────────────
-- public=false:这是整个设计的支点,不能改。
-- file_size_limit 与 works 一致,避免"staging 收得下但 works 收不下"导致
-- 校验通过却搬不过去。
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('staging', 'staging', false, 500 * 1024 * 1024, null)
on conflict (id) do update
  set public = false,                       -- 幂等地强制回私有
      file_size_limit = excluded.file_size_limit;

-- (原本想把说明写进 comment on schema storage,但 storage schema 不归本角色
--  所有,会报 42501。说明留在此处即可 —— 注释的价值在于被读到,不在于它
--  存放的位置。)

-- MIME 白名单刻意留空(null):allowed_mime_types 匹配的是**客户端声明的
-- Content-Type 头**(storage 源码 uploader.ts 里 mimeType 直接取自请求头,
-- 从不看字节),对攻击者毫无约束力,把它当内容校验是安全剧场。真正的类型
-- 判定在 finalize 里用 Range 读魔数完成。

-- ── 客户端对 staging 的权限:只能写自己目录,且不能读回 ──────────────
drop policy if exists "staging_insert_self" on storage.objects;
create policy "staging_insert_self"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'staging'
    and (storage.foldername(name))[1] = (select app.current_user_id())::text
  );

-- 允许 update 是为了 upsert 重传(同一内容哈希重复发布)。
drop policy if exists "staging_update_self" on storage.objects;
create policy "staging_update_self"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'staging'
    and (storage.foldername(name))[1] = (select app.current_user_id())::text
  );

-- 允许 delete 自己的暂存对象:用户取消发布时能立即清掉,不必等 cron。
drop policy if exists "staging_delete_self" on storage.objects;
create policy "staging_delete_self"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'staging'
    and (storage.foldername(name))[1] = (select app.current_user_id())::text
  );

-- ⚠️ 刻意**不建 SELECT 策略**。客户端不需要读回 staging,而少一条读策略就
-- 少一个把未校验内容暴露出去的途径。服务端走 service_role,不受 RLS 约束。

-- ── kill switch 覆盖 staging ──────────────────────────────────────
-- 20260818030000 的开关只列了 works/thumbnails。staging 是新的写入入口,
-- 不一并纳入,就等于给攻击者留了一条开关关不掉的路。
drop policy if exists kill_switch_storage_write on storage.objects;
create policy kill_switch_storage_write on storage.objects
  as restrictive
  for insert to authenticated
  with check (
    bucket_id not in ('works', 'thumbnails', 'staging')
    or (select app.switch_on('storage_write'))
  );

-- ── 守卫:staging 永远不能变成公开桶 ───────────────────────────────
-- 这是整个两阶段设计唯一的致命失效模式 —— 一旦 staging 变公开,未校验内容
-- 立刻可被公开 URL 直取,而且因为公开桶绕过 RLS,上面那些策略一条都拦不住。
-- 用触发器而不是靠人记得,理由与 20260818000000 的隔离桶守卫相同。
create or replace function app.assert_staging_private()
returns trigger
language plpgsql
security definer
set search_path = storage, public, pg_temp
as $$
begin
  if new.id in ('staging', 'quarantine') and new.public then
    raise exception
      '% 桶必须保持私有:它存放未经校验/已下架的内容,'
      '公开桶会绕过 RLS 使其可被任意下载', new.id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_assert_staging_private on storage.buckets;
create trigger trg_assert_staging_private
  before insert or update on storage.buckets
  for each row execute function app.assert_staging_private();

-- ── 孤儿清扫 ──────────────────────────────────────────────────────
-- 客户端不调 finalize、或调用前崩溃,staging 就会留下永远不会被提升的对象,
-- 照样占存储、照样计费。这是两阶段模式**已知的**代价,必须主动收拾。
--
-- 24 小时:远大于任何一次正常上传+校验的时长,又不至于让垃圾堆积太久。
create or replace function app.purge_stale_staging()
returns integer
language plpgsql
security definer
set search_path = storage, public, pg_temp
as $$
declare
  v_count integer;
begin
  -- 只删元数据行会在 S3 留下孤儿文件(官方明确:删对象应走 Storage API,
  -- 不要用 SQL)。所以这里**不删**,只把待清理的挑出来交给 Edge Function,
  -- 由它用 Storage API 真正删除。这个函数只负责回答"哪些该删"。
  select count(*) into v_count
  from storage.objects
  where bucket_id = 'staging'
    and created_at < now() - interval '24 hours';
  return v_count;
end;
$$;

revoke all on function app.purge_stale_staging() from public;
grant execute on function app.purge_stale_staging() to service_role;

comment on function app.purge_stale_staging is
  '返回超过 24h 未被提升的 staging 对象数量。刻意不做删除 —— 用 SQL 删 '
  'storage.objects 只会摘掉元数据行并在 S3 留下孤儿文件(Supabase 官方口径:'
  '删除对象必须走 Storage API)。真正的删除由 Edge Function 执行。';
