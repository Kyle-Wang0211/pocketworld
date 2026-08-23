-- 收紧 works.description 到 30 字 —— 缩小唯一剩下的长自由文本入口
-- =====================================================================
-- 背景(2026-08-23 合规收敛):
--   本产品的自由文本入口只剩两个 —— works.title(≤100)与 works.description。
--   昵称改走预生成白名单池,评论/私信冷启动不开放。description 原为 ≤5000,
--   是 title 的 50 倍,风险密度最高却最不被注意。
--
-- 为什么必须落在 DB 而不是只改 UI:
--   `works_insert_own` 策略仍允许 authenticated 角色直接 INSERT public.works
--   (publish_service.dart 就是这么写的)。所以 TextField 的 maxLength 是可绕过
--   的软限制 —— 直接调 Supabase REST API 即可塞满 5000 字。CHECK 才是真边界。
--   注意 20260818050000 收口的是 storage.objects(文件桶),不是 works 表(数据行);
--   两者是不同的门,别把前者当成后者已经关上了。
--
-- 为什么现在就上而不是等将来:
--   《具有舆论属性或社会动员能力的互联网信息服务安全评估规定》第三条把"新增
--   相关功能"列为重新评估的情形。先砍掉再加回 = 触发两次自评估+报送,还要给
--   应用商店重新提交一次平台状态截图。一次到位比来回改便宜。
--
-- 不改 title(≤100)的原因:它是必填项,且 100 字与 30 字在审核成本上同量级
-- (腾讯云 TMS 按条计费,不按字数)。

-- ── 1. 先看清影响面 ───────────────────────────────────────────────
-- apply 前请先单独跑这句,确认要截断多少行:
--   select count(*), max(char_length(description)) from public.works
--   where char_length(description) > 30;

-- ── 2. 截断超长存量 ───────────────────────────────────────────────
-- ⚠️ 有损操作。产品尚未上线,works 预期只有测试数据;若线上已有真实作品,
--    先跑上面的 select 确认,不要盲目 apply。
do $$
declare
  affected int;
begin
  select count(*) into affected
  from public.works
  where char_length(description) > 30;

  if affected > 0 then
    raise notice '[tighten_description] 截断 % 行超长 description', affected;
    update public.works
    set description = left(description, 30)
    where char_length(description) > 30;
  end if;
end $$;

-- ── 3. 加新约束 ───────────────────────────────────────────────────
-- 不删旧的 ≤5000 约束:它的自动生成名不可靠(内联 CHECK 由 Postgres 命名),
-- 而两条 CHECK 并存是安全的 —— 实际生效的永远是更严的那条。少一次
-- "猜约束名猜错导致静默没删掉"的失败模式。
alter table public.works
  add constraint works_description_len_30
  check (description is null or char_length(description) <= 30);

comment on constraint works_description_len_30 on public.works is
  '2026-08-23 合规收敛:描述字段收到 30 字。放宽前须重新做安全评估报送。';
