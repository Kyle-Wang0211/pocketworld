# third_party

## thermion_dart 0.3.4+1 的本地补丁

`pubspec.yaml` 的 `dependency_overrides` 指向 `~/Developer/thermion_dart_pw`,
那是 pub 上 `thermion_dart 0.3.4+1` 的可编辑副本。**那个目录不在版本控制里**,
所以这里放的是让它**可复现**的两样东西:

| 文件 | 是什么 |
|------|--------|
| `thermion_dart_0.3.4+1_pw.patch` | 相对 pub 原版的完整 diff(17 文件 / 585 行) |
| `thermion_dart_0.3.4+1_pw.md` | 每处改动是什么、为什么、上线前怎么消 |

### 重放

```bash
cp -R ~/.pub-cache/hosted/pub.dev/thermion_dart-0.3.4+1 ~/Developer/thermion_dart_pw
rm -rf ~/Developer/thermion_dart_pw/.dart_tool
cd ~/Developer/thermion_dart_pw
patch -p1 < <本仓>/third_party/thermion_dart_0.3.4+1_pw.patch
```

已验:重放结果与现用副本**逐字节一致**(`diff -rq`,排除 `.dart_tool`)。

### 🔴 上线前

补丁里 17 个文件中,**只有 `Texture_setExternalImagePlatform` 那一组是上游没有的**;
其余都是上游 HEAD(0.6.0-pre.0)已有的回填,升级即整段删除。详见同目录的 `.md`。

真·新增那一组已推到 fork:
https://github.com/nmfisher/thermion/pull/355
