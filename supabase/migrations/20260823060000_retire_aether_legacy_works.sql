-- 退役云端重建时代遗留的 works 行,并把不变量约束转正
-- =====================================================================
-- 背景(大白话):2026-05 时产品还有**云端重建** —— App 把照片传到自家
-- Aether 后端跑重建,数据库里记的是一个任务号而不是文件路径:
--     model_storage_path = 'aether://job_4713d7c6f95c447aa6785ae76a078ac6'
-- 对比同期正常的行,那才是真的文件位置:
--     model_storage_path = '<uid>/Antique_Camera.glb'
-- 2026-07-13 云端那条线被整体删除(改纯本地重建),任务号从此指向空气。
-- 2026-08-23 实测:works 桶里**没有**这些对象(storage.objects 查 job_ 前缀为 0)。
--
-- 为什么现在才处理:其中一行是 visibility='public' 但 published_at 为空,
-- 而 feed 查询带 .not('published_at','is',null) ⇒ 它被静默过滤,三个月没人看见。
-- **这其实是走运** —— 若当初 published_at 有值,它会正常出现在广场,
-- 用户点进去是个打不开的空壳(无文件、无缩略图、file_size_bytes 也为空)。
--
-- 所以不能"补上 published_at 让它显示",那等于把坏了三个月的空壳推上首页。
-- 正确处理是退役:标记 removed + deleted_at,行本身留着(将来查历史还看得到),
-- 与既有的下架语义一致。
--
-- ⚠️ 只处理 model_storage_path 以 'aether://' 开头的行。
--    同期还有一行 published_at 为空但路径正常(<uid>/horned…),
--    实测其文件仍在 storage 里 —— 那是**从未发布过的正常私有草稿**,不动。
--
-- 改动前的完整数据已备份:
--   tool/backups/works_aether_legacy_before_removal_20260823.json

update public.works
set moderation_status = 'removed',
    deleted_at = coalesce(deleted_at, now())
where model_storage_path like 'aether://%'
  and moderation_status <> 'removed';


-- ── 把 20260823050000 的 NOT VALID 约束转正 ──────────────────────────
-- 那条约束当初必须建成 NOT VALID,正是因为存在上面这行违反者
-- (moderation_status='ok' + visibility='public' + published_at IS NULL)。
-- 违反者退役后全表已满足,可以 VALIDATE —— 之后 Postgres 会保证
-- **不存在**"状态显示已通过且公开、实际却被 feed 静默过滤"的行。
--
-- VALIDATE 会全表扫一遍做检查,但不取 ACCESS EXCLUSIVE 锁(只取
-- SHARE UPDATE EXCLUSIVE),不阻塞读写。表很小,瞬间完成。
alter table public.works validate constraint works_visible_needs_published_at;
