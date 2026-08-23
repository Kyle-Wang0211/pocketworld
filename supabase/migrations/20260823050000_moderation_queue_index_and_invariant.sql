-- 审核队列的索引 + "已通过却不可见"的不变量约束
-- =====================================================================
-- 这两条不是自己想出来的,是照抄内容审核系统的通行数据模型实践:
--   · "content moderation services require strategic indexing on **status and
--      timestamp combinations**" —— 队列查询永远是 status 过滤 + 时间排序
--   · "Content Moderation Services must maintain comprehensive logs for legal
--      compliance" —— 审计已在 admin-approve-work 里做
--   · Drupal Workflows 把状态与合法转换**显式声明**出来,而不是让规则散落在
--     各个调用点。本表的状态机太小(ok/under_review/removed)不值得建表,
--     但其中一条**跨列不变量**必须显式化 —— 见下。


-- ── 1. 待审队列的索引 ───────────────────────────────────────────────
-- 队列查询是:moderation_status='under_review' AND published_at IS NULL
--            ORDER BY created_at   (先来先审)
-- 2026-08-23 实测该查询走的是 **Seq Scan**。当前数据量下无所谓,但队列是
-- 天然增长的表,而且这条查询会被审核端反复调用。
-- 用部分索引:待审行只是全表的极小一撮,没必要为它索引整张表。
create index if not exists idx_works_review_queue
  on public.works (created_at)
  where moderation_status = 'under_review' and published_at is null;

comment on index public.idx_works_review_queue is
  '待审队列:status 过滤 + created_at 排序。admin-approve-work 的 list 走它。';


-- ── 2. 🔴 不变量:通过审核且公开的作品,必须有 published_at ──────────
-- 为什么必须在 DB 层立这条:feed 查询带 `.not('published_at','is',null)`
-- (keyset 分页的游标也是 (published_at, id) 元组),所以
--   moderation_status='ok' + visibility='public' + published_at IS NULL
-- 的行会被**静默过滤掉** —— 状态显示"已通过、公开",实际对任何人都不可见,
-- 包括作者自己。没有任何报错,没有任何日志,只是永远不出现。
--
-- 这不是假想:2026-08-23 在生产库实测,**已经存在 1 行**处于该状态
-- (id 8f3de8dc…,title "scan 2026-05-04 22:57",2026-05 创建的 glb)。
-- 所以这条约束真正防的是"放行流程忘了写 published_at"这一类实现错误。
--
-- ⚠️ 用 NOT VALID:这是给已有脏数据的表加约束的标准做法 ——
--    新行/被更新的行必须满足,存量行不做回溯检查,迁移不会因为那一行而失败。
--    修完历史数据后可以执行:
--      alter table public.works validate constraint works_visible_needs_published_at;
--    (那一行怎么修是产品决策:补 created_at 会让它按原时间落在 feed 中间,
--     补 now() 会让一个 5 月的作品跳到顶部。留给人决定,迁移不擅自改数据。)
alter table public.works
  add constraint works_visible_needs_published_at
  check (
    published_at is not null
    or moderation_status <> 'ok'
    or visibility <> 'public'
    or deleted_at is not null
  )
  not valid;
