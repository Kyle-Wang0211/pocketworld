# Prompt For Agent: DA3-BASE K30@504x896 Mac Quality Test

你是另一个 coding/benchmark agent。请在本机继续做 DA3-BASE 多视角配置筛选，不要重新发散路线。当前目标是只先在 Mac 上测试 `K30@504x896` 的质量数据，判断它是否值得后续上 iPhone。不要先做手机测试。

## 背景和结论基线

我们正在找 DA3-BASE 商用可走路线的手机可运行矩形配置。`K3-K12` 属于之前 DA3-LARGE / non-commercial 路线，不要列入当前产品排序，也不要继续测试 Large。当前只看 `DA3-BASE pose-conditioned fp16 CoreML`。

已知结果：

| Config | Mac infer/group | Pose RMSE ↓ | Pose P90 ↓ | Edge corr ↑ | Highlight conf ↑ | iPhone status |
|---|---:|---:|---:|---:|---:|---|
| K40@392x392 | 13.636s | 11.6656 | 17.9116 | 0.1891 | 11.7498 | PASS, infer 18.519s, CPU peak one-core 576%, device 95.9% |
| K40@448x896 | 79.908s | 8.8149 | 13.2814 | 0.1335 | 6.5498 | INFER FAIL, killed near 3074MB |
| K40@504x896 | 98.201s | 7.8586 | 11.2957 | 0.1316 | 10.5716 | INFER FAIL, killed near ActiveHard 3072MB |
| K30@588x1036 | 107.656s | 8.9662 | 12.5433 | 0.1199 | 11.0043 | INFER FAIL, iOS high-watermark |

Interpretation so far:

1. The `504x896` rectangle currently has the best Mac geometry at K40, but K40 is too memory-heavy for iPhone 14 Pro single-pass CoreML.
2. The next hypothesis is `K30@504x896`: keep the promising 504x896 rectangle, reduce K from 40 to 30 to lower CoreML workspace.
3. First run Mac quality only. If Mac quality is poor, do not waste time preparing phone resources.

## Repos And Important Files

Primary benchmark repo:

`/Users/kaidongwang/Developer/Aether3D-cross`

Current product-summary repo:

`/Users/kaidongwang/Documents/progecttwo`

Important docs to update after results:

`/Users/kaidongwang/Developer/Aether3D-cross/docs/da3_benchmark_ledger_2026-05-24.md`

`/Users/kaidongwang/Documents/progecttwo/docs/da3_multiview_benchmark_rank_2026-05-24.md`

Important scripts:

`/Users/kaidongwang/Developer/Aether3D-cross/scripts/da3_official_stage/export_da3_pose_coreml.py`

`/Users/kaidongwang/Developer/Aether3D-cross/scripts/da3_official_stage/compare_coreml_quality_rectangular.py`

Existing DA3-BASE CoreML output directory:

`/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_flutter/ios/Runner/Models/DA3-BASE-CoreML`

DA3-BASE model path:

`/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_flutter/ios/Runner/Models/DA3-BASE`

## Required Task

Run Mac quality for:

`DA3-BASE pose K30@504x896 fp16 CoreML`

Use the same quality comparator and same scenes as the K40 rectangular runs:

`scan97`, `scan105`, `scan118`

Use `CPU_ONLY` for CoreML comparator to keep the metric comparable.

## Step 1: Check Whether The K30@504x896 Package Exists

From:

`/Users/kaidongwang/Developer/Aether3D-cross`

Run:

```bash
find pocketworld_flutter/ios/Runner/Models/DA3-BASE-CoreML -maxdepth 1 -name 'DA3BASE_504x896_N30_pose.mlpackage' -print -exec du -sh {} \;
```

If it exists, do not re-export unless the package is obviously broken.

If it does not exist, export it with:

```bash
source .venv-da3/bin/activate
python scripts/da3_official_stage/export_da3_pose_coreml.py \
  --model-path pocketworld_flutter/ios/Runner/Models/DA3-BASE \
  --out-dir pocketworld_flutter/ios/Runner/Models/DA3-BASE-CoreML \
  --out-name DA3BASE_504x896_N30_pose \
  --k 30 \
  --height 504 \
  --width 896 \
  --direct-package-save
```

Expected behavior:

1. It may be quiet for a long time during `torch.jit.trace`.
2. The K40@504 export previously took `trace 1464.8s`, `convert/save 136.6s`, package `779MB`.
3. K30@504 should be meaningfully smaller/faster than K40 but may still take a long time.
4. Do not use MPS PyTorch exact tensor benchmark for this. Previous K40 rectangular PyTorch/MPS path failed with invalid MPS attention buffer size. Use CoreML package + comparator.

## Step 2: Add K30@504x896 To Comparator Configs

Open:

`/Users/kaidongwang/Developer/Aether3D-cross/scripts/da3_official_stage/compare_coreml_quality_rectangular.py`

Find the `CONFIGS = [` list and add:

```python
RectModelConfig("K30_504x896", BASE_COREML_DIR / "DA3BASE_504x896_N30_pose.mlpackage", 30, 504, 896),
```

Keep existing configs. Do not remove K40@392, K40@448, K40@504, or 588 rows unless explicitly asked.

Use `apply_patch` for edits if you are an agent with file-edit tools.

## Step 3: Run Mac Quality Comparator

Run:

```bash
source .venv-da3/bin/activate
python scripts/da3_official_stage/compare_coreml_quality_rectangular.py \
  --configs K40_392x392 K40_504x896 K30_504x896 \
  --out /tmp/pocketworld_da3_rectangular_coreml_quality_k30_504_20260524 \
  --compute-unit CPU_ONLY
```

If time is limited and K40 baseline rows are already trusted, it is acceptable to run only:

```bash
source .venv-da3/bin/activate
python scripts/da3_official_stage/compare_coreml_quality_rectangular.py \
  --configs K30_504x896 \
  --out /tmp/pocketworld_da3_rectangular_coreml_quality_k30_504_20260524 \
  --compute-unit CPU_ONLY
```

But if possible, include `K40_392x392` in the same run for a same-session sanity baseline.

Expected output file:

`/tmp/pocketworld_da3_rectangular_coreml_quality_k30_504_20260524/rect_quality_results.json`

Parse `summary_rows` and record:

- `predict_s`
- `pose_rmse`
- `pose_p90`
- `pose_median`
- `edge_corr`
- `conf_mean`
- `highlight_conf_mean`
- `depth_edge_ratio`

## Step 4: Decision Criteria

Compare `K30@504x896` against these two references:

1. `K40@392x392` phone-safe fallback:
   - RMSE `11.6656`
   - P90 `17.9116`
   - Edge corr `0.1891`
   - Highlight conf `11.7498`
   - iPhone PASS

2. `K40@504x896` Mac best but phone fail:
   - RMSE `7.8586`
   - P90 `11.2957`
   - Edge corr `0.1316`
   - Highlight conf `10.5716`
   - iPhone FAIL near 3072MB

Call `K30@504x896` promising if:

- Pose RMSE is clearly better than `K40@392x392`, ideally near or below `9.5`.
- Pose P90 is clearly better than `K40@392x392`, ideally near or below `14`.
- Highlight conf is not catastrophically lower than K40@504; ideally near `10+`.
- Edge corr may remain lower than square 392; do not reject solely on Edge corr if pose is strong.
- Mac infer/group should be lower than K40@504 and ideally near or below K30@588 (`107.656s`), but quality matters first.

If `K30@504x896` is promising, recommend phone-testing it next.

If it is not promising, recommend `K30@448x896` Mac quality next, then only phone-test if Mac quality survives.

## Step 5: Update Tables

Update:

`/Users/kaidongwang/Developer/Aether3D-cross/docs/da3_benchmark_ledger_2026-05-24.md`

Add a row in "Mac Quality Sweep C: Rectangular High-Resolution DA3-BASE" for `K30@504x896`.

Update "Current Decision Snapshot" / "Current Interpretation" / "Recommended Next DA3-Only Tests" according to the result.

Also update:

`/Users/kaidongwang/Documents/progecttwo/docs/da3_multiview_benchmark_rank_2026-05-24.md`

Add `K30@504x896` to the compact metric table and decision rank table.

Table columns must include:

`配置 | Mac 推理/组 | Pose RMSE ↓ | Pose P90 ↓ | Edge corr ↑ | 高光 conf ↑ | 手机 CPU 峰值`

For phone CPU, write `未测` unless you actually run the phone test. Do not invent CPU peak.

## Output To User

Return a concise Chinese summary:

1. Whether export was needed and how long it took.
2. The exact Mac quality row for `K30@504x896`.
3. A comparison against `K40@392`, `K40@448`, and `K40@504`.
4. Recommendation: phone-test `K30@504x896` or move to `K30@448x896`.
5. Paths to updated docs and raw JSON.

Do not run phone testing unless the user explicitly asks after seeing the Mac result.
