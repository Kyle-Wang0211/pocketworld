-- [KEYSET-PAGINATION 2026-08-23] feed 分页从 offset 改为 keyset(seek)。
--
-- 病因:offset 分页在"边翻页边有新内容插到顶部"时会**静默漏项** ——
-- 整列下移一位,原本在 offset 处的那条挪到 offset+1,第二页从下一条开始,
-- 中间那条对该用户永远不出现。客户端的 id 去重只挡得住重复,挡不住漏。
-- (本仓修过一次同类:此前只拉一次 limit:20 且无加载更多,第 21 个作品
--  对所有人永久不可见。这是它更隐蔽的变体。)
--
-- 第二个病因:排序键 published_at **不唯一**。keyset 的硬性前提是排序键能
-- 唯一确定一个位置,否则边界上值相同的行会被跳过或重复。故补主键 id 作次级键。
--
-- 查询形态(DESC):
--   WHERE (published_at, id) < (last_published_at, last_id)
--   ORDER BY published_at DESC, id DESC
--   LIMIT n
-- PostgREST 无原生元组比较,客户端用等价展开式:
--   published_at < T  OR  (published_at = T AND id < I)
--
-- 本索引让上面这条走索引而不是排序:列顺序与 ORDER BY 完全一致,
-- 谓词与既有 idx_works_published_at 相同(公开且已发布)。
create index if not exists idx_works_published_keyset
  on public.works (published_at desc, id desc)
  where visibility = 'public' and published_at is not null;

-- 旧的单列索引保留:它仍服务于不带游标的首页请求与其它按时间的查询。
-- (删除它没有收益,而 CONCURRENTLY 之外的 drop 会短暂持锁。)
