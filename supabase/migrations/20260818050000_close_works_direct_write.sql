-- 收口:撤销客户端对 works 公开桶的直写权限
-- =====================================================================
-- 这一步让两阶段上传从"并行存在的一条更安全的路"变成**唯一的路**。
--
-- 在此之前:客户端既能走 staging→校验→提升,也能直接把字节写进公开的
-- works 桶。后者绕过全部内容校验 —— 只要那条路还开着,前面做的校验就是
-- 可选项,而攻击者永远选可选项里对自己有利的那个。
--
-- 收口后的不变量(这是整个设计的目标):
--   **公开桶的写入权限只有 service_role 持有。客户端只能写永不公开的
--   staging 桶,内容经服务端 Range 校验通过后由服务端搬进公开桶。**
--
-- 端到端已验证(2026-08-18,临时测试账号,测后已清理):
--   合法 PLY   → finalize 200 {"kind":"ply"},落 works,staging 清空
--   MZ 可执行体 → finalize 422 {"reason":"exe_mz"},**未进 works**,
--                 取证副本进 quarantine,审计 head_hex=4d5a9000
--
-- 影响面已核实:客户端代码里对 works 桶只剩**读**(getPublicUrl),
-- 唯一的写路径 publish_service.uploadModel 已改走 staging。

-- ── 撤销 INSERT / UPDATE ──────────────────────────────────────────
-- 只撤写,不动读与删:
--   SELECT 保留 —— 作者要能看自己的私有作品(works_select_owner);
--   DELETE 保留 —— 作者要能删自己的作品(works_delete_self),这是 Apple
--                  UGC 要求的"用户可移除自己的内容",不能顺手关掉。
drop policy if exists "works_insert_self" on storage.objects;
drop policy if exists "works_update_self" on storage.objects;

-- ── 守卫:防止将来有人把直写权限加回来 ─────────────────────────────
-- 这条策略本身不授予任何权限(RESTRICTIVE 只做减法)。它的作用是:即便日后
-- 有人重新创建了 works_insert_self 之类的 PERMISSIVE 策略,这条 RESTRICTIVE
-- 仍会把 authenticated 角色对 works 桶的写入一律否决。
--
-- 为什么要这样一条"多余"的策略:被撤销的策略是**看不见的**,几个月后没人
-- 记得这里曾经有过一条,而"加一条 insert 策略"看起来是完全无害的操作。
-- 用 RESTRICTIVE 把意图固化下来,让重新开门这件事必须是显式的。
create policy works_no_client_write on storage.objects
  as restrictive
  for insert to authenticated
  with check (bucket_id <> 'works');

create policy works_no_client_update on storage.objects
  as restrictive
  for update to authenticated
  using (bucket_id <> 'works');

-- thumbnails 不在此列:它走 storage-sign-upload broker,由服务端签发一次性
-- 上传凭证并校验路径/大小/类型,不是无门槛直写。works 之所以特殊,是因为
-- 它承载的是几十到几百 MB 的模型文件,且此前完全没有服务端内容校验。
