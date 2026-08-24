# Four workstreams: executable gate and write contract

Date: 2026-08-19 (Asia/Shanghai)

Status: `SIGNED DECISIONS RECORDED / PRE-WRITE CONTRACT ALIGNED`

This contract converts `HANDOFF_20260819_four_workstreams.md` into an
implementation-safe dependency graph, exact write domains, stop conditions,
and acceptance gates. It does not supersede the handoff's iron laws. The signed
record at the end of this document is authoritative for the three decisions it
names; superseded alternatives have been removed from the operative sections
below instead of being left as contradictory choices.

## Frozen inputs

| Input | Frozen identity | Current limitation |
|---|---|---|
| Handoff | SHA-256 `fd3520d3897b207bf91e093ffdae9ea15b169e543e82bfb06bb08475258c0a11` | 377-line signed task contract; its ②/④/execution-order entries are the current authority |
| Verification report | SHA-256 `2bb3bb38a572ff6d009e99eec415e1ae744f7dba7b3e51a2ff172a9aee76b6e4` | 86-line pre-signature audit; its pending-decision section is superseded by the signed record below |
| Product `/Users/kaidongwang/Developer/pocketworld` | `main@bf159e38c5ed5483bc80fae9a2f5a8683e8e2d3c` | WIP count drifted from 43 to 35 during read-only reconnaissance; treat the checkout as actively changing, use an isolated worktree, and merge dirty files hunk-by-hunk |
| Research benchmark | `research/casdiffmvs-official-replication-2026-08-17@b119067` | architecture documents are frozen Git objects from `40fd9ab`; both identities must remain in evidence |
| ORT source | detached `2e2543f` (`v1.29.0`) | one pre-existing modified file: `cmake/external/onnxruntime_external_deps.cmake` |
| Pipeline source bytes | `official_aether_sfm_c.cc` SHA-256 `e597e85b...`; `aether_sfm_c.h` SHA-256 `3dd3fde...` | Git control files are dataless; revision/status cannot be frozen yet |
| Product Metal matcher | SHA-256 `08a6d4854a79ed80947bba3083bec68db753c0f4f57ac6dacb07c22b70121156` | production metric is squared Sampson, not legacy pair-level w99 |

No implementation may claim the pipeline revision until its Git metadata is
restored and a read-only status/diff succeeds with submodules ignored.

## Correct dependency graph

```text
environment recovery
  ├─ ② GTO provenance + pipeline implementation + native promotion
  ├─ ① ORT 1.29 private-boundary product integration
  └─ ⑥ #32145 upstream fix work in an isolated ORT build tree

(① accepted + current production matcher)
  → ③ durable streaming scheduler + final refined reconciliation
  → ④ code-ready atomic dense delivery resolver + render-only LOD
      → enabling delivery requires ⑤ fog <1% verdict + user visual approval

② is an independent arm. Its progress or acceptance does not block ③ or ④.

⑤ checkpoint fog benchmark
  → dormant until the user supplies an exact checkpoint path/hash
```

① and ⑥ may read the same frozen source revision, but must not share a mutable
checkout or build output after source-fix work starts.

## Environment recovery authorization requested

No deletion has been performed. The recommended recoverable cleanup is exactly:

- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/build` — 3.870 GiB
- `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/build-ios-device-dawn` — 2.669 GiB
- `/Users/kaidongwang/Developer/pocketworld/build` — 1.188 GiB
- `/Users/kaidongwang/Library/Developer/Xcode/DerivedData` — 0.648 GiB

Expected release: approximately 8.375 GiB. Free space independently increased
from roughly 6.53 GiB to 8.5 GiB during read-only reconnaissance, so the same
cleanup would currently target roughly 16.9 GiB free. Recheck immediately before
deletion. Do not delete `/Users/kaidongwang/ort_ios_build`,
Pods, or any other `build*` directory under this authorization.

After space recovery, authorize a minimal File Provider fetch only for:

- `/Users/kaidongwang/Documents/Aether3D/.git/worktrees/Aether3D-cross/HEAD`
- `/Users/kaidongwang/Documents/Aether3D/.git/worktrees/Aether3D-cross/commondir`
- `/Users/kaidongwang/Documents/Aether3D/.git/worktrees/Aether3D-cross/gitdir`
- `/Users/kaidongwang/Documents/Aether3D/.git/config`
- `/Users/kaidongwang/Documents/Aether3D/.git/packed-refs` only if HEAD resolution requires it

Do not fabricate or edit Git metadata. The first check must be read-only:

```bash
GIT_OPTIONAL_LOCKS=0 git -C /Users/kaidongwang/Developer/Aether3D-cross \
  status --porcelain=v1 --untracked-files=no --ignore-submodules=all
```

## Decisions requested: recommended bundle

1. Product work occurs in a new isolated worktree from product commit
   `bf159e38...`; no current WIP is reverted or silently adopted.
2. Raise the product deployment target to iOS 16.3, matching the frozen ORT
   1.29 WebGPU artifact. Do not silently rebuild it for iOS 14–16.2.
3. Capture-time dense inference uses immutable `image.name` plus ARKit pose as a
   speculative input. No speculative result is deliverable. Final refined SfM
   poses invalidate and replay the complete dependency closure before MD5
   acceptance. A native live-BA-pose ABI is deferred. Workstream ③ does not
   modify the existing live sparse stream; it attaches a separate dense bridge
   at the capture coordinator and consumes existing outputs read-only.
4. Implement official dense fusion in the private native dense boundary, not
   Dart, because OpenCV remap, float order, 30M-point scale, and byte-MD5 are
   hard gates.
5. Dense write protocol is per-reference chunks plus
   `official_dense.ply.partial`, fsync, length/point-count/MD5 verification,
   atomic rename, then a final atomic `complete` manifest.
6. Feature flag semantics (signed):
   - flag off: today's sparse behavior remains byte-for-byte unchanged;
   - flag on + dense complete and integrity-valid: deliver dense;
   - flag on + dense missing, incomplete, or corrupt: deliver the existing
     validated sparse artifact; never expose a partial dense file and never
     return empty-handed.
   Sparse fallback is the signed success behavior. The former proposal to stay
   in `processing` or an explicit recoverable-failure state is rejected.
7. Old-ORT coexistence smoke uses a real Dart ORT 1.15.1 session with the fixed
   MobileSAM model/input before and after the new ORT run (`A→B→A`, then
   `B→A→B`). It does not claim restoration of a missing production MobileSAM
   entry point.
8. One ORT inference may be in flight. Thermal `serious/critical`, queue
   pressure, memory pressure, and insufficient disk pause work without dropping
   a registered frame. Journal transitions are atomic and fsynced.
9. Disk reserve before starting a dense task is:
   `predicted intermediates + final PLY + partial PLY + 1 GiB`.
10. Full-resolution PLY remains the delivery/upload artifact. A16 display point
    budget is not invented now; it will be signed after device measurement and
    affects render-only LOD.
11. Workstream ⑤ remains idle until a checkpoint is supplied. Its wrapper will
    accept checkpoint as an argument/environment input rather than persistently
    editing `CKPT=` in the canonical script.
12. For #32145, diagnosis is complete but ORT source editing, remote issue
    comments, pushes, and a PR require a separate explicit choice after the
    independent evidence review.
13. Workstream ④ may be implemented and tested with its flag default-off, but
    the dense delivery flag may not be enabled until a new checkpoint produces
    fog below 1% and the user passes the true-color PLY visual review.

## ② GTO write domain — signed, HOLD released

The user selected the COLMAP known-pose family on 2026-08-19. The complete
operative recipe is fixed and may not be mixed with the discarded experiment
recipe or with ORB-SLAM gates:

- guided epipolar pre-gate `max_error = 4.0 px` (COLMAP default);
- pass `16.0` to each of the two audited entry points that directly consume a
  squared pixel-domain threshold; do not reinterpret the units of other APIs;
- ratio `0.8`, with mutual cross-check enabled;
- leave all five current TVG “colmap defaults” call sites unchanged;
- install no ORB gate, and do not move w99 pixel values into a threshold.

The old `10.2 ms/pair` and reprojection `1.1563` results identify the discarded
`1.96 px + ratio 0.6` experiment only. They are not commitments for this signed
recipe. Device alternating A/B, the surface-roughness ruler, and full
registration must be measured again; the current 132-frame acceptance fixture
must remain `registered == captured == 132`.

The provenance below is retained as the historical reason ORB-derived gates
were rejected, not as an unresolved HOLD condition. Legacy `100.8 px`, `46 px`,
and pair-level w99 values cannot be converted into production squared Sampson
thresholds without point-level coordinates and matrices.

ORB-SLAM3 source is frozen at official UZ-SLAMLab commit
[`4452a3c4ab75b1cde34e5505a36ec3f9edcdc4c4`](https://github.com/UZ-SLAMLab/ORB_SLAM3/commit/4452a3c4ab75b1cde34e5505a36ec3f9edcdc4c4).
It establishes the actual sequence and branch conditions:

- double-sided `5.991 * sigmaSquare` is a real post-triangulation gate for two
  dimensional/monocular observations; stereo residuals use `7.8 * sigmaSquare`;
- `cosParallaxRays < 0.9998` is a triangulation-entry pre-gate only in the
  non-inertial branch; the inertial branch uses `0.9996`, and stereo can bypass
  the fixed `0.9998` condition;
- the epipole test is a match-candidate pre-gate, not a post-gate. Its official
  expression is `d^2 < 100 * mvScaleFactors[level]`, equivalent to
  `d < 10 * sqrt(scaleFactor)`, not `10 * scale`. It is enabled only when both
  observations are non-stereo and the first keyframe has no second camera.

The present source cannot decide either remaining translation:

- ARKit gravity/pose validation does not implement ORB-SLAM3's `mbInertial`, IMU
  preintegration, or initialization semantics, so neither `0.9996` nor
  `0.9998` can be selected merely from the word “ARKit”;
- current matches retain point-row indices and x/y. The v2 extraction path can
  persist COLMAP `FeatureKeypoint::ComputeScale()` in pixels, but not ORB octave;
  older carrier/host paths may have no true scale. ORB's
  `mvScaleFactors[level]` is a dimensionless pyramid multiplier. No official
  DSP-SIFT `(octave, sublevel)` to ORB-level mapping exists in the frozen
  sources.

Therefore the epipole gate cannot be installed under an “official formula only”
claim, even after adding an octave field. Treating all points as level 0 or
substituting COLMAP pixel scale would be a project-defined rule and needs an
explicit exception to the iron law. The gates must retain their real positions
in the control flow; they may not be relabeled as three generic post-gates.

Proposed pipeline create/modify scope after provenance and Git recovery:

- create `official_pipeline/include/gto_match_policy_v1.h`
- create `official_pipeline/src/gto_match_policy_v1.cc`
- create `official_pipeline/tests/gto_match_policy_v1_test.cc`
- modify `official_pipeline/src/official_aether_sfm_c.cc`
- modify `official_pipeline/include/aether_sfm_c.h`
- modify `official_pipeline/src/pwofficial_export_shim.c`
- modify `CMakeLists.txt`

Proposed product create/modify scope:

- modify `vendor/official_sfm/include/aether_sfm_c.h`
- modify `vendor/official_sfm/include/official_sfm_c.h`
- modify `vendor/official_sfm/src/pwofficial_export_shim.c`
- modify `vendor/official_sfm/src/pwofficial_gpu_match.mm` only if an accepted
  policy cannot reuse its existing squared-Sampson path
- modify `vendor/official_sfm/pwofficial_abi_symbols.txt`
- modify `vendor/official_sfm/scripts/generate_official_header.py`
- modify `vendor/official_sfm/scripts/verify_boundary.sh`
- modify `vendor/official_sfm/scripts/rebuild_native.sh`
- modify `vendor/official_sfm/scripts/build_xcframework.sh`
- modify `vendor/official_sfm/scripts/promote_official_pair.py`
- modify `vendor/official_sfm/tests/test_official_gpu_carrier_promotion_contract.sh`
- modify generated `vendor/official_sfm/libs/ios-arm64/libpwofficial_core.a`
- modify generated `vendor/official_sfm/Frameworks/PWOfficialSfm.xcframework/Info.plist`
- modify generated `vendor/official_sfm/Frameworks/PWOfficialSfm.xcframework/ios-arm64/PWOfficialSfm.framework/PWOfficialSfm`
- modify generated `vendor/official_sfm/Frameworks/PWOfficialSfm.xcframework/ios-arm64/PWOfficialSfm.framework/Info.plist`
- modify generated `vendor/official_sfm/Frameworks/PWOfficialSfm.xcframework/ios-arm64/PWOfficialSfm.framework/Headers/aether_sfm_c.h`
- modify generated `vendor/official_sfm/Frameworks/PWOfficialSfm.xcframework/ios-arm64/PWOfficialSfm.framework/Headers/official_sfm_c.h`
- modify generated `vendor/official_sfm/Frameworks/PWOfficialSfm.xcframework/ios-arm64/PWOfficialSfm.framework/Headers/official_sfm_io_c.h`
- modify generated `vendor/official_sfm/Frameworks/PWOfficialSfm.xcframework/ios-arm64_x86_64-simulator/PWOfficialSfm.framework/PWOfficialSfm`
- modify generated `vendor/official_sfm/Frameworks/PWOfficialSfm.xcframework/ios-arm64_x86_64-simulator/PWOfficialSfm.framework/Info.plist`
- modify generated `vendor/official_sfm/Frameworks/PWOfficialSfm.xcframework/ios-arm64_x86_64-simulator/PWOfficialSfm.framework/Headers/aether_sfm_c.h`
- modify generated `vendor/official_sfm/Frameworks/PWOfficialSfm.xcframework/ios-arm64_x86_64-simulator/PWOfficialSfm.framework/Headers/official_sfm_c.h`
- modify generated `vendor/official_sfm/Frameworks/PWOfficialSfm.xcframework/ios-arm64_x86_64-simulator/PWOfficialSfm.framework/Headers/official_sfm_io_c.h`
- modify `lib/official_aether_sfm_ffi.dart` (currently user-dirty; hunk merge only)
- explicit exclusion: `lib/official_capture/sfm_live_recon.dart` is read-only.
  No workstream-owned hunk is permitted, including telemetry/logging; its
  pre/post SHA must remain identical in the isolated worktree. GTO telemetry
  must be proven through the existing exported FFI/device-log path. If that is
  impossible, stop and request a separately signed write-domain expansion.
- create `test/gto_match_policy_test.dart`
- create `test/gto_telemetry_contract_test.dart`

Promotion must become one atomic core + carrier + framework SHA transaction.
The existing carrier/framework pair script cannot safely promote a changed GTO
core. Tests must inject interruption after each of the three promotion stages;
restart must automatically retain or restore the previous complete verified SHA
tuple, never activate a mixed tuple, and pass ABI/boundary verification after
recovery.

## ① private ORT 1.29 dense boundary write domain

Create:

- `vendor/official_dense/official_dense.podspec`
- `vendor/official_dense/Info.plist`
- `vendor/official_dense/include/pwofficial_dense_c.h`
- `vendor/official_dense/src/pwofficial_dense_ort.cc`
- `vendor/official_dense/src/pwofficial_dense_sim_backend.c`
- `vendor/official_dense/src/pwofficial_dense_fusion.cc`
- `vendor/official_dense/pwofficial_dense_abi_symbols.txt`
- `vendor/official_dense/Resources/casdiffmvs_v5_clipfix.onnx`
- `vendor/official_dense/licenses/onnxruntime-LICENSE`
- `vendor/official_dense/licenses/onnxruntime-ThirdPartyNotices.txt`
- `vendor/official_dense/README.md`
- `vendor/official_dense/PROVENANCE.md`
- `vendor/official_dense/scripts/build_xcframework.sh`
- `vendor/official_dense/scripts/verify_boundary.sh`
- `vendor/official_dense/scripts/promote_official_dense.py`
- `vendor/official_dense/scripts/rebuild_native.sh`
- `vendor/official_dense/tests/test_official_dense_promotion_contract.sh`
- generated `vendor/official_dense/Frameworks/PWOfficialDense.xcframework/Info.plist`
- generated `vendor/official_dense/Frameworks/PWOfficialDense.xcframework/ios-arm64/PWOfficialDense.framework/PWOfficialDense`
- generated `vendor/official_dense/Frameworks/PWOfficialDense.xcframework/ios-arm64/PWOfficialDense.framework/Info.plist`
- generated `vendor/official_dense/Frameworks/PWOfficialDense.xcframework/ios-arm64/PWOfficialDense.framework/Headers/pwofficial_dense_c.h`
- generated `vendor/official_dense/Frameworks/PWOfficialDense.xcframework/ios-arm64_x86_64-simulator/PWOfficialDense.framework/PWOfficialDense`
- generated `vendor/official_dense/Frameworks/PWOfficialDense.xcframework/ios-arm64_x86_64-simulator/PWOfficialDense.framework/Info.plist`
- generated `vendor/official_dense/Frameworks/PWOfficialDense.xcframework/ios-arm64_x86_64-simulator/PWOfficialDense.framework/Headers/pwofficial_dense_c.h`
- `lib/official_dense_ffi.dart`
- `lib/official_capture/dense_ort_engine.dart`
- `lib/official_capture/dense_ort_stage_launcher.dart`
- `test/official_dense_ffi_contract_test.dart`
- `test/dense_ort_stage_launcher_test.dart`
- `integration_test/official_dense_dual_ort_smoke_test.dart`

Modify:

- `ios/Podfile`
- `ios/Podfile.lock` (currently user-dirty; generated and merged hunk-by-hunk)
- `ios/Runner.xcodeproj/project.pbxproj`
- `ios/Runner/Info.plist`
- `lib/main.dart`
- `THIRD_PARTY_NOTICES` (currently user-dirty; hunk merge only)

The private framework's actual export set must equal its ABI allowlist and must
not expose `OrtGetApiBase` or any `Ort*` symbol.

## ③ streaming scheduler write domain

Create:

- `lib/official_capture/dense_stream_models.dart`
- `lib/official_capture/dense_source_selection.dart`
- `lib/official_capture/dense_freeze_policy.dart`
- `lib/official_capture/dense_job_store.dart`
- `lib/official_capture/dense_worker.dart`
- `lib/official_capture/dense_stream_scheduler.dart`
- `lib/official_capture/dense_capture_bridge.dart`
- `lib/official_capture/dense_ply_assembler.dart`
- `lib/official_capture/dense_integrity_manifest.dart`
- `test/dense_source_selection_test.dart`
- `test/dense_freeze_policy_test.dart`
- `test/dense_job_store_test.dart`
- `test/dense_stream_scheduler_test.dart`
- `test/dense_fusion_contract_test.dart`
- `test/dense_ply_assembler_test.dart`
- `test/dense_integrity_manifest_test.dart`
- `test/fixtures/official_dense/streaming_132_source_lists.json`

Modify:

- `lib/ui/official_capture/ar_capture_page.dart`
- `lib/official_capture/dense_ort_stage_launcher.dart`
- `lib/main.dart`
- `vendor/official_dense/include/pwofficial_dense_c.h`
- `vendor/official_dense/src/pwofficial_dense_fusion.cc`
- `vendor/official_dense/pwofficial_dense_abi_symbols.txt`
- `vendor/official_dense/scripts/verify_boundary.sh`

The existing live sparse implementation contains an unreadable-spool-JPEG
`continue` path. The current handoff forbids changing that stream in workstream
③, so the dense bridge must hold the existing archive lease, validate every
durable JPEG before registration, and prove by fault injection that this path is
unreachable during an accepted dense run. If it remains reachable, acceptance
stops and a separately signed minimal live-sparse safety patch is required; the
implementation may not silently lose a registered frame.

For every ③ or ④ change to `ar_capture_page.dart`, the only permitted purposes
are attaching/detaching the separate dense bridge to already-produced capture
outputs and resolving a completed delivery artifact. Shutter behavior, capture
guidance, frame registration, sparse preview, and all other capture interaction
remain outside the write domain.

## ④ dense delivery write domain

Create:

- `lib/official_capture/delivery_artifact.dart`
- `lib/official_capture/dense_preview_loader.dart`
- `test/delivery_artifact_test.dart`
- `test/dense_preview_loader_test.dart`

Modify:

- `lib/ui/me_page.dart`
- `lib/community/publish_service.dart`
- `lib/ui/official_capture/sfm_resume_wait_page.dart`
- `lib/ui/official_capture/ar_capture_page.dart`
- `lib/ui/official_capture/sparse_cloud_viewer_page.dart`
- `test/publish_service_test.dart`
- `test/scan_record_pipeline_kind_test.dart`
- `test/point_cloud_display_policy_test.dart`

No partial dense file may be exposed as `official_dense.ply`. Render-only LOD
must never replace, reorder, or overwrite the full delivery PLY.

## Acceptance and stop conditions

Implementation proceeds test-first. Minimum acceptance bundle:

- all new ①/②/③/④ flags default off; install and measure one workstream variable
  at a time;
- after a completed delivery-flag-on run, set the flag off, restart, and perform
  a new full acceptance capture with the frozen fixture/input; the complete
  sparse behavior and delivered sparse bytes must equal the pre-change baseline
  byte-for-byte. Resolver-only replay does not satisfy this acceptance;
- delivery flag on + integrity-valid complete dense: resolve only the complete
  dense PLY;
- delivery flag on + missing, truncated, length/count-mismatched, or MD5-invalid
  dense: fault injection resolves to the validated sparse PLY, never a partial
  dense path and never an empty result;
- interrupt core/carrier/framework promotion after each stage: the active
  installation must automatically remain on or roll back to the previous
  complete core+carrier+framework SHA tuple; no mixed tuple may become active,
  and boundary verification must pass after recovery;
- GTO flag on: non-zero telemetry and
  `registered == expected == captured`; for the current acceptance capture this
  is the non-negotiable `132 == 132 == 132` red line;
- exact `image.name` identity, immutable ordered source lists, persisted noise,
  and a complete dependency key;
- queue-full, process-kill/restart, disk-low, missing JPEG, duplicate-name, and
  final-tail fault injection without dropped or duplicated work;
- same device/backend/input/noise/model batch-vs-stream PLY MD5 equality;
- full PLY length equals `headerEnd + 15 * pointCount` and manifest hash/counts;
- dual ORT `A→B→A` and `B→A→B` golden outputs with no symbol interference;
- simulator validates only ABI/unsupported; WebGPU, heat, memory, and MD5 require
  a clean uninstall/reinstall on the target device and a checked build stamp;
- any non-finite value, registration loss, trajectory anomaly, MD5 mismatch,
  jetsam, or unaccounted dirty-file collision stops work and returns to the user.

The A16 display budget and full-app RSS/jetsam limit remain measurement outputs,
not guessed constants. Workstream ⑤'s `1%–4.13%` fog gray zone also requires an
explicit verdict before a new checkpoint is classified.

## Authorization boundary after the signed decisions

The obsolete “GTO remains HOLD” choice has been removed. The signature record
below authorizes the GTO recipe, the ②/③ dependency split, and sparse fallback.
The user's opening instruction “读 HANDOFF_20260819_four_workstreams.md，开工”
and the later condition “执行 agent 动手写产品代码之前……4 个真洞还是要先补”
together authorize in-scope local product/pipeline implementation only after
these four holes are closed, in the exact write domains above and in isolated
worktrees. They do not authorize destructive cache cleanup or unrelated side
effects. Any exception should name the numbered decision or file path. Remote
issue comments, branch pushes, PR creation, device install, checkpoint
evaluation, and destructive cache cleanup remain separately gated where their
exact inputs or targets are not already authorized by the user.

---

# 用户签字记录(2026-08-19,由主会话代录;三项均为用户原话拍板)

1. **GTO 口径已签 = COLMAP known-pose 家(px 阈值、不要 octave)⇒ ②组 HOLD 解除。**
   完整配方(全 COLMAP 血统):guided 极线预门 max_error=4.0px(两个预平方入口传 16.0)、
   ratio=0.8、互检开、现行 5 处 TVG 默认值原样保留、不装任何 ORB 门;
   w99 数字不进阈值。旧实验数字(10.2ms/1.1563)不再是承诺,装机后重测。
   ⇒ 本文档正文已改为“signed, HOLD released”;ORB 证据只保留为历史拒绝理由。
2. **③ 与 ② 解耦已签**:③ 的依赖 = ① accepted + 现生产匹配器;② 进度不阻塞 ③。
   ⇒ 本文档依赖图已改为“① accepted + 现生产匹配器 → ③”,并明确②不阻塞。
3. **④ 失败语义已签 = 回退交付 sparse,永不空手**(今日行为)。
   ⇒ 本文档“决定 6”与验收包均已改为 sparse fallback;旧
   processing/recoverable-failure 提案不再是正文选项。

核查回执(五路按源核查,含本文档 4 真洞 6 瑕疵清单;未吸收项须在任何产品/管线写入前关闭):
/Users/kaidongwang/Documents/progecttwo/VERIFICATION_20260819_report_check.md
对齐的 HANDOFF 版本:SHA256 前缀 fd3520d3897b207b(签字条目已写入其 ②/④/执行顺序三节)。

# 用户签字补录(2026-08-20,主会话代录)

4. **成品位姿口径已签 = B(live_recon 位姿)**。成品稠密 = 拍摄结束时刻 live_recon 状态
   (位姿+稀疏点)喂官方 batch 链的产物;MD5 验收改绑该参照;冻结闭包升级为三输入
   (位姿/depth range/有序 top-10 均等于终值才算成品级);refined 位姿照常产出留档但
   不定义稠密成品。**③ 装机前必做**:schedule_sim 改"回放演化 live 输入"口径实测
   重推尾巴与 MD5(Mac,零手机);**验收必做**:一次性 B-vs-A 稠密对拍(粗糙度尺+
   换种子地板;B 掉出地板=异常旗停下找用户)。新工程件:native live_recon 位姿导出
   getter(照 get_preview_tracked 模式)。本条同时解除③的"位姿待拍板"阻断。
   ⚠️ 尚未签的一件:④ 的"sparse 自身损坏 ⇒ 返回类型化 null(不硬塞坏文件)"待用户确认。
   对齐 HANDOFF SHA256 前缀 1ce949cbe52d665d。
