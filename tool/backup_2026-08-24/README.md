# PocketWorld 采集素材离线备份(2026-08-24)

零成本方案:**内容寻址去重 + Cloudflare R2 免费额度**。

## 为什么需要

2026-08-24 的 iCloud `dataless` 事故永久销毁了 ≥528 个文件。
本机**没有任何备份**(无外置磁盘、Time Machine 从未配置、APFS 本地快照为空)。
代码与文档已推 GitHub;本目录处理 GitHub 装不下的二进制采集素材。

## 关键数字

| | |
|---|---|
| 原始素材 | 10,702 MB / 11,456 文件 |
| 去重后 | **2,007 MB / 1,878 对象** |
| 重复率 | **83.6%**(5.33×) |
| R2 免费额度 | **10 GB 存储 + 100 万写/月 + 出站免费** |

重复来自 07-24 的 6 次 `matcher_ab` 会话(同一批照片配不同 matcher)
与 `pre_install`/`post_install` 配对快照。

⚠️ 已排除 139 个 `dataless` 文件(内容不存在,无法备份)。

## 覆盖范围

| root | 来源 | 文件 |
|---|---|---|
| `ICLOUD_CAPS` | `~/Documents/progecttwo/.device_backups.nosync` | 8,676 |
| `PW_DEV_BK` | `~/pw_device_backups` | 2,013 |
| `DEV_BK` | `~/Developer/device-backups` | 767 |

## 你要做的三步

1. 注册 Cloudflare,进 R2,建一个 **private** bucket(名字用 `pw-backup`)
2. 建 R2 API Token,然后跑 `rclone config`
   - 类型选 `s3` → provider 选 `Cloudflare`
   - endpoint 填 `https://<账号ID>.r2.cloudflarestorage.com`
   - remote 名字取 `r2`
3. `./upload.sh`

## 还原

```
./restore.sh r2 pw-backup /要还原到的目录
```

脚本会拉回 blobs、按清单重建**全部 11,456 个文件**(含重复),
再逐文件复算 sha256 —— 不通过就非零退出。

## 设计说明

- `blobs/` 里每个对象以自身 sha256 命名 ⇒ 重复内容天然只存一份
- 本地 `blobs/` 是**硬链接**,新增磁盘占用为 0
- `manifest.tsv` 四列:`sha256 · 字节数 · root · 相对路径`,
  用相对路径以便在别的机器上还原
