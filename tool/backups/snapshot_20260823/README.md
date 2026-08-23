# Supabase 迁移原点快照 — 2026-08-23

这是**迁离 Supabase 官方托管版之前**的完整状态快照。它的用途只有一个:
**当"从阿里云(或任何托管方)迁出"出问题时,这里有一个干净的原点可以回退。**

## 为什么现在做

阿里云托管 Supabase 的迁移工具是**单向的** —— 只有迁入、没有迁出文档/工具/先例,
且它会在库里植入自有 schema 与账号(文档明令不得删改)。将来 dump 出来时,
官方 `supabase db dump` 的过滤逻辑不认识那些阿里云特有对象。

⇒ **只有在还没迁过去之前留下的这份快照,才能分清"哪些是阿里云加的、哪些本来就有"。**
过了这个窗口就分不清了。

## 内容与完整性(已验证)

| 文件 | 内容 | 能进 git 吗 |
|---|---|---|
| `schema.sql` | 74 条 RLS 策略 / 31 个触发器 / 31 个函数 / 31 张表 / 52 个索引;含 `app` schema | ✅ 纯结构 |
| `roles.sql`  | 角色定义,已确认不含凭证字样 | ✅ |
| `data.sql`   | 全部数据,**含 auth.users 的 bcrypt 密码哈希与邮箱** | ❌ **已 gitignore** |

`data.sql` 请自行保存到加密位置(密码管理器附件 / 加密磁盘 / 私有对象存储)。
`SHA256SUMS.txt` 用于将来校验这份快照没被改动过。

## 怎么用它恢复(官方路径)

来自 supabase.com/docs/guides/self-hosting/restore-from-platform:

```bash
psql "$DB_URL" \
  --single-transaction \
  --variable ON_ERROR_STOP=1 \
  --file roles.sql \
  --file schema.sql \
  --command 'SET session_replication_role = replica' \
  --file data.sql
```

⚠️ `session_replication_role = replica` 不是可选项 —— 它在导入期关闭触发器,
**防止密码列被二次加密**。漏了这句,所有用户都会无法登录。

## 官方明确**不包含**在 dump 里的东西

- **Storage 对象**(16 个 / 159MB)—— 要单独搬,官方原文 "not covered in this guide"
- **Edge Functions**(11 个)—— 代码在本仓库,但要重新部署
- **Secrets / API Keys** —— 要重新生成
- 非默认扩展、外部登录提供商配置、SMTP 配置

## 已知的一次性代价

JWT secret 在托管版与自建之间不同 ⇒ **平台签发的既有 token 全部失效,所有用户需重新登录一次**。
截至本快照,系统只有 **1 个用户** —— 这个代价此刻等于零。这是"越早迁越无痛"的硬证据。

## 生成方式

在项目根目录(supabase link 已配置)执行,需要 Docker 运行:

```bash
supabase db dump --linked --role-only              -f roles.sql
supabase db dump --linked                          -f schema.sql
supabase db dump --linked --use-copy --data-only   -f data.sql
```
