# 研究仓 84 项未提交改动清单(2026-08-23 纯只读盘点)

仓库 `~/Developer/Aether3D-cross/pocketworld_research_benchmarks`
分支 `research/casdiffmvs-official-replication-2026-08-17`,上游领先 **0 笔**(已提交部分与远端同步)。

⚠️ 原作者会话 `progecttwo-3c` 已结束。机器上另外两个会话(`1b` XRSLAM / `9b` 内容审核合规)
均确认与此无关。**没有人知道这些改动的意图。**

本盘点**只读**:没有 add / commit / checkout / clean 任何东西。

---

## 一、14 个删除 —— 整个 `tools/python/sfm_cmp/` 树

这是决定性的一组。删掉的是 08-19 之前的 SfM 对比工具链。

| 文件 | 行数 | 最后一次提交 |
|---|---|---|
| `tools/python/sfm_cmp/.gitignore` | 9 | 2026-06-17 85fa5df SfM cross-platform pose unification: DS |
| `tools/python/sfm_cmp/pw_sfm_align.py` | 60 | 2026-06-17 85fa5df SfM cross-platform pose unification: DS |
| `tools/python/sfm_cmp/run_colmap_chain.sh` | 17 | 2026-06-17 85fa5df SfM cross-platform pose unification: DS |
| `tools/python/sfm_cmp/sfm_dsp/align_dsp.py` | 47 | 2026-06-17 85fa5df SfM cross-platform pose unification: DS |
| `tools/python/sfm_cmp/sfm_dsp/align_prod.py` | 47 | 2026-06-17 85fa5df SfM cross-platform pose unification: DS |
| `tools/python/sfm_cmp/sfm_dsp/build_pairs.py` | 25 | 2026-06-17 85fa5df SfM cross-platform pose unification: DS |
| `tools/python/sfm_cmp/sfm_dsp/run_dsp.sh` | 15 | 2026-06-17 85fa5df SfM cross-platform pose unification: DS |
| `tools/python/sfm_cmp/sfm_dsp/run_prod.sh` | 14 | 2026-06-17 85fa5df SfM cross-platform pose unification: DS |
| `tools/python/sfm_cmp/sfm_hd/align_hd.py` | 47 | 2026-06-17 85fa5df SfM cross-platform pose unification: DS |
| `tools/python/sfm_cmp/sfm_hd/run_glomap_hd.sh` | 15 | 2026-06-17 85fa5df SfM cross-platform pose unification: DS |
| `tools/python/sfm_cmp/sfm_hd/run_hd.sh` | 28 | 2026-06-17 85fa5df SfM cross-platform pose unification: DS |
| `tools/python/sfm_cmp/sfm_v6/align_v6.py` | 47 | 2026-06-17 85fa5df SfM cross-platform pose unification: DS |
| `tools/python/sfm_cmp/sfm_v6/robust_align.py` | 57 | 2026-06-17 85fa5df SfM cross-platform pose unification: DS |
| `tools/python/sfm_cmp/sfm_v6/run_v6.sh` | 21 | 2026-06-17 85fa5df SfM cross-platform pose unification: DS |

### 这些文件被什么取代了吗

工作树里现存的 SfM 对比 / 对齐相关脚本:
```
./experiments/sfm_cmp_rescue_2026-08-18
./tools/python/da3_streaming_alignment_diagnostics.py
./tools/python/da3_product_runtime_alignment_audit.py
./tools/python/da3_upstream_geometry_alignment_audit.py
./experiments/sfm_cmp_rescue_2026-08-18/pw_sfm_align.py
./data/official_da3_base_k35_streaming_2026_05_30/diagnostics/alignment_debug_2026_06_01
./experiments/sfm_cmp_rescue_2026-08-18/sfm_v7/robust_align.py
./experiments/sfm_cmp_rescue_2026-08-18/sfm_v7/align_v7.py
./experiments/sfm_cmp_rescue_2026-08-18/sfm_v6/robust_align.py
./experiments/sfm_cmp_rescue_2026-08-18/sfm_v6/align_v6.py
./experiments/sfm_cmp_rescue_2026-08-18/sfm_v8/robust_align.py
./experiments/sfm_cmp_rescue_2026-08-18/sfm_hd/align_hd.py
./experiments/sfm_cmp_rescue_2026-08-18/sfm_dsp/align_dsp.py
./experiments/sfm_cmp_rescue_2026-08-18/sfm_dsp/align_prod.py
./experiments/da3_multiview_k_resolution_sweep_2026_05/algorithm/metric_depth_alignment.dart
./data/official_da3_base_k35_strict_seq_2026_06_02/diagnostics/official_da3_upstream_geometry_alignment_2026_06_04
./data/official_da3_base_k35_strict_seq_2026_06_02/diagnostics/official_da3_dart_downstream_policy_alignment_2026_06_05
./data/official_da3_base_k35_strict_seq_2026_06_02/diagnostics/official_adjacent_sim3_alignment_clouds_full_414
./data/official_da3_base_k35_strict_seq_2026_06_02/diagnostics/official_da3_product_runtime_alignment_audit_2026_06_05
./data/official_da3_base_k35_strict_seq_2026_06_02/diagnostics/official_da3_streaming_overlap_alignment_update_2026_06_04
```

---

## 二、7 个修改

### `experiments/casdiffmvs_blendmvg_scratch_2026-08-16/tools/make_blendmvg_list.py`  (+6 −1)
```diff
-_REPO_VAL = Path(__file__).resolve().parents[3] / "tools/python/diffmvs/lists/blend/val.txt"
+# ⚠️ 脚本被拷到别处时 parents[3] 会 IndexError(2026-08-19 在租的机器上踩到)。
+# 兜底成 None,靠 --val-from 或下面的硬编码。
+try:
+    _REPO_VAL = Path(__file__).resolve().parents[3] / "tools/python/diffmvs/lists/blend/val.txt"
+except IndexError:
+    _REPO_VAL = None
```

### `experiments/casdiffmvs_wgsl_port_2026-08-17/bench/bench_main.cc`  (+41 −13)
```diff
+#include <cstdlib>
-  for (uint32_t f = 0; f < h.n_frames; ++f) {
+  // PW_BENCH_LOOPS:同一批素材连跑 N 遍(默认 1=原行为),量持续负载下的热降频曲线。
+  // 🔴 循环必须在这层(帧循环层)而不是壳层:壳层重复调 bench_run 每遍都重建会话
+  //    (真机实测 732ms)并重复 parity,会污染热曲线。parity 只在第一遍做,后面纯计时。
+  int loops = 1;
+  if (const char* lv = getenv("PW_BENCH_LOOPS")) loops = std::max(1, atoi(lv));
+  if (loops > 1)
+    printf("持续负载模式:%d 遍 × %u 帧(热曲线看逐帧时间戳,t=帧结束时刻)\n",
+           loops, h.n_frames);
+
+  const char* frames_base = cur;
```

### `experiments/casdiffmvs_wgsl_port_2026-08-17/bench/build_ios_bench_ort.sh`  (+3 −1)
```diff
+MODEL_FP16="$RES_DIR/casdiffmvs_v5_fp16.onnx"   # 有则一并入包(壳用 PW_BENCH_MODEL 选)
-# ── 4. 资源:model + inputs ──
+# ── 4. 资源:model + inputs(fp16 模型存在则双模型入包)──
+[ -f "$MODEL_FP16" ] && cp "$MODEL_FP16" "$APP/"
```

### `experiments/casdiffmvs_wgsl_port_2026-08-17/bench/ios_shell_main.mm`  (+5 −2)
```diff
-    NSString* model  = [b pathForResource:@"casdiffmvs_v5" ofType:@"onnx"];
+    // PW_BENCH_MODEL = bundle 内模型基名(不含 .onnx),默认 fp32 母本 —— 双模型入包免装两次
+    const char* mname = getenv("PW_BENCH_MODEL") ?: "casdiffmvs_v5";
+    NSString* model  = [b pathForResource:@(mname) ofType:@"onnx"];
-    if (!model || !inputs) { fprintf(stderr, "🔴 bundle 里找不到 model/inputs\n"); exit(2); }
+    if (!model || !inputs) { fprintf(stderr, "🔴 bundle 里找不到 model(%s)/inputs\n", mname); exit(2); }
+    fprintf(stdout, "模型:%s.onnx\n", mname);
```

### `experiments/mvs_pose_ablation_2026-08-18/tools/fuse_arm.py`  (+3 −1)
```diff
-REPO = os.path.expanduser(
+# ⚠️ 硬编码 Mac 路径会让脚本在别的机器上直接 ModuleNotFoundError
+# (2026-08-19 在租的机器上踩到)。允许用 DIFFMVS_REPO 覆盖。
+REPO = os.environ.get("DIFFMVS_REPO") or os.path.expanduser(
```

### `experiments/mvs_pose_ablation_2026-08-18/tools/measure_arms.py`  (+3 −1)
```diff
-SPIKE = os.path.expanduser("~/Documents/progecttwo/_artifacts/lightglue_spike")
+# ⚠️ 同 run_arm.py 那个坑:硬编码路径换机器就废。允许 SPIKE_DIR 覆盖。
+SPIKE = os.environ.get("SPIKE_DIR") or os.path.expanduser(
+    "~/Documents/progecttwo/_artifacts/lightglue_spike")
```

### `experiments/mvs_pose_ablation_2026-08-18/tools/run_arm.py`  (+3 −1)
```diff
-REPO = os.path.expanduser(
+# ⚠️ 硬编码 Mac 路径会让脚本在别的机器上直接 ModuleNotFoundError
+# (2026-08-19 在租的机器上踩到)。允许用 DIFFMVS_REPO 覆盖。
+REPO = os.environ.get("DIFFMVS_REPO") or os.path.expanduser(
```

---

## 三、63 个未跟踪 —— 按目录归组

- `experiments/casdiffmvs_wgsl_port_2026-08-17/fp16/` — 10 项
- `tools/python/gpu_sfm_ab/` — 8 项
- `tools/python/` — 8 项
- `experiments/floater_removal_2026-08-05/labeling/` — 8 项
- `experiments/floater_removal_2026-08-05/bisect_20260807/` — 7 项
- `experiments/floater_removal_2026-08-05/birth_gate_ab/` — 6 项
- `experiments/floater_removal_2026-08-05/` — 5 项
- `tools/capture_ux/` — 3 项
- `experiments/mvs_pose_ablation_2026-08-18/tools/` — 3 项
- `experiments/floater_removal_2026-08-05/scale_knife/` — 3 项
- `experiments/floater_removal_2026-08-05/bisect_20260807/ctl_k12/` — 1 项
- `experiments/floater_removal_2026-08-05/bisect_20260807/aug5bin_k12/` — 1 项

---

# 结论:那 14 个删除是**已文档化操作的后半截**,不是误伤

追到提交信息就清楚了:

```
4657203  抢救 sfm_cmp 的 214 个结果文件(5.3MB),之后删掉 7GB 数据本体
         ✓ 已在远端
```

**"之后删掉"就是计划本身。** 08-18 的搬家已经完成并推送,只有"删掉旧位置"没提交。

## 逐项核对损失面

| 类别 | 数量 | 提交删除后会怎样 |
|---|---|---|
| Python 对齐脚本 | 7 | **零损失** —— 逐字节相同地存在于已提交、已推送的 `experiments/sfm_cmp_rescue_2026-08-18/`,且那边还多出 `sfm_v7/` `sfm_v8/` 两代新版 |
| shell 启动脚本 | 6 | 从工作树消失,但**在 git 历史里**(`run_colmap_chain.sh` 17 行 / `run_v6.sh` 21 行 等,`git show HEAD:<path>` 随时可取回) |
| `.gitignore` | 1 | 同上 |

7 个 Python 文件的逐字节同一性已实测:
`pw_sfm_align.py` · `sfm_dsp/{align_dsp,align_prod,build_pairs}.py` ·
`sfm_hd/align_hd.py` · `sfm_v6/{align_v6,robust_align}.py` — **7/7 sha256 一致**。

## 建议

**可以提交这个删除**,风险已经查清且很低。但它仍是别人的工作,原作者会话
(`progecttwo-3c`)已结束,机器上另外两个会话(`1b` XRSLAM / `9b` 内容审核合规)
都确认与此无关 —— **所以需要用户点头**。

如果要保守一点:提交删除**之前**,先把那 6 个 shell 脚本 + `.gitignore`
从 git 历史里取出来存一份到 `progecttwo/`,再删。成本约 1 分钟。

## 另外 70 项(7 修改 + 63 未跟踪)

与本次删除无关,是 08-16 ~ 08-19 的实验产物:
`casdiffmvs_wgsl_port` 的 fp16 一组、`gpu_sfm_ab`、`floater_removal_2026-08-05`
的标注/二分/birth_gate 几组、`mvs_pose_ablation_2026-08-18` 的工具。
这些该不该入库,取决于研究仓对"实验中间产物"的收录口径 —— 我没有依据判断。
