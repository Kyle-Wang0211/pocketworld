# 混合精度 MMA 核:实测结果(2026-09-03 23:xx,主线亲手实现与验证)

## 改动(生产 TU `vendor/official_sfm/src/pwofficial_gpu_match_dawn.cc`)
- vendored Dawn 的 Metal 后端登记第三条子组矩阵配置 `f16 in → f32 out 8×8×8`
  (`PhysicalDeviceMTL.mm`,证据链见 2026-09-03-sgmatrix-probe-m3.md);
- TU 新增混合后端:探测 `sgcfg_f16_f32`、按需请求 `ShaderF16`、`MixedWgsl()` 从**同一份 WGSL
  单一真源**派生变体(只把 Left/Right 与 A/B/Bsh 换 f16,**Res/accSh/门/平局语义一字不改**)、
  描述子上传改 u8→f16(**无缩放,u8 在 f16 中精确**)、`DescBytes` 减半;
- guided 两趟 shader 同样走 `MixedWgsl`(否则按 f32 读 f16 数据 ⇒ 0 匹配,已被 ABI 测试抓到并修);
- 可观测面加 `f16_f32=` 与 `mixed=`(装机≠生效的核验手段);env
  `OFFICIAL_AETHER_MATCH_DAWN_KERNEL=mixed` 选中(默认仍 f32,单变量纪律)。

## 为什么逐字节精确(构造性)
u8 ≤255 在 f16 中精确(11 位有效数字);逐积 ≤65,025、K=128 总和 ≤262,144(L2=512 的
Cauchy-Schwarz 上限)均在 f32 的 24 位尾数内精确 ⇒ 点积与 f32 路径**完全相同的整数**。

## 门(全部主线亲手跑,mixed=1 已由可观测面证明生效)
| 门 | 结果 |
|---|---|
| parity 套件 19 案例三重金标准 | **PASS** |
| 全量闸 20 帧库 | **162/162 逐字节** |
| 全量闸 51 帧库 | **534/534 逐字节** |
| guided 对拍(Metal v1 vs 混合 Dawn)148 案例 | **79,082 对全部逐字节相同,0 发散** |
| ABI 测试(probe_batch/驻留/参数/guided) | **0 失败** |

## 速度(镜像 ABBA,7 reps × warmup 2,同 8192² 真实夹具)
| 臂 | GPU p50 | wall p50 |
|---|---|---|
| a1 f32 基线 | 13.889 | 14.853 |
| b1 **混合** | **10.993** | 11.551 |
| b2 **混合** | **8.893** | 9.453 |
| a2 f32 基线 | 13.844 | 14.818 |
| native Metal 括号 | — | 5.280 |

**括号干净**(两个 f32 臂相差 0.045ms)⇒ 采纳。paired:f32 13.867 → 混合 9.943 =
**−3.92ms / −28.3%**。离 Metal 从 ~2.6× 收窄到 **~1.7-2.1×**(混合两臂自身差 2.1ms,
机器仍有 HydraRenderingService 97% + WeChat 51%,安静窗可复测收紧)。

## 下一刀(f16 腾出的预算,尚未做)
Bsh 从 16KiB 降到 8KiB ⇒ 空出 8KiB。之前被 32KiB 预算枪毙的两把刀复活:
(a) 列 tile 32→64(B 复用翻倍、barrier 减半);(b) 真双缓冲。单变量分别量。

## 装机前置(未做)
1. 重编 **iOS** 侧 Dawn(`aether_cpp/build-ios-device-dawn`,带同一补丁);
2. 更新 `build_xcframework.sh` 的 `PWOFFICIAL_DAWN_SHA256` 钉子并记入 PROVENANCE;
3. 决定 dawn 后端的默认核(建议:检测到 `f16_f32` 即默认 mixed);
4. 🔴 **速度闸尚未达标**:我此前写死"dawn 上机前置 = 主机 8192² GPU ≤ Metal 4.9ms",
   现在是 8.9-11.0ms(1.7-2.1×)。**是否在未追平前上机,需用户裁决。**
