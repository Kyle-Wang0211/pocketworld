#!/usr/bin/env bash
# bench 里的 vio 代码是生产的**镜像**,不是分叉。真源在 pocketworld。
# 改动一律改生产,然后跑这个同步过来。跑完会自证逐字节一致。
set -euo pipefail
# 2026-09-23(录制回放):真源从 zero-arkit-preview-20260922(feat/ios-zero-arkit-integration @ cfe7d44)
#   挪到 bench-replay-20260923(feat/bench-replay,= feat/per-frame-k-host 之上)。那条线是这条线的祖先
#   (cfe7d44 → +13 个逐帧内参提交 → 回放),所以不是换分叉,是往前走。要临时从别的树同步:
#   PW_BENCH_SYNC_SOURCE=<pocketworld 工作树> ./.sync_from_integration.sh
#   🔴 从更老的树同步会把 PwXrslamLive.swift 换回没有回放入口的版本 ⇒ 台架编不过;
#      下面「多出生产没有的文件」那道闸会先把回放文件点名出来。
# 2026-09-24(合一):P / F / R 三段的默认真源都改成同一棵树 bench-unified-20260924(分支 bench/unified =
#   bench/full-chain-168-fixes + git merge bench/lidar-ruler(含 feat/bench-replay))。旧树(bench-replay-20260923 /
#   bench-full-chain-168-fixes / bench-lidar-ruler-20260924)原样保留,可用各段的 PW_BENCH_*_SOURCE 临时改回。
P="${PW_BENCH_SYNC_SOURCE:-/Users/kaidongwang/.config/superpowers/worktrees/pocketworld/bench-unified-20260924}"; B=/Users/kaidongwang/Developer/arloopbench
# 2026-09-18: 加上 ffi/ —— engine_pose_poller.dart 要 XrslamBindings 与 xrslamOk,
# 缺了这一层台架直接 6 个 undefined。镜像范围要跟着依赖走,不能只镜像"我改过的目录"。
mkdir -p "$B/lib/vio/ffi"
cp "$P"/lib/vio/ffi/*.dart             "$B/lib/vio/ffi/"
cp "$P"/lib/vio/pose/*.dart            "$B/lib/vio/pose/"
cp "$P"/lib/vio/render/*.dart          "$B/lib/vio/render/"
cp "$P"/assets/materials/*.filamat     "$B/assets/materials/"
# 2026-09-22(端到端拍摄探针 zero_arkit_capture_probe_page.dart):镜像范围再跟着依赖走一次。
#   lib/vio/render/zero_arkit_capture_probe_page.dart
#     → lib/vio/pose/vio_ar_pose_provider.dart(已镜像)
#         → lib/vio/capture/{zero_arkit_capture_runtime, zero_arkit_photo_api,
#                            zero_arkit_scale_provenance, camera_time_offset}.dart
#         → lib/vio/quality/{initialization_window, pose_confidence, …}.dart
#         → lib/official_dome/ar_pose.dart(ARPose / ARFrameSaveSpec / ARFrameSaveResult)
#         → lib/official_capture/metric_rescale.dart(→ lib/vio/quality/scale_observability.dart)
#   传递依赖(编译时冒出来的,逐个说明):
#     lib/vio/timebase/*.dart  ← camera_time_offset.dart 要 IosTimebaseChannel
#                                (ios_timebase_channel → clock_offset_estimator + timebase_contract;
#                                 整目录镜像,内部互相 import,单挑三个文件迟早漏)
#     lib/quality/quality_compute.dart ← lib/vio/quality/texture_sufficiency.dart 只要
#                                        它的一个常量 kQualitySignatureSide
#     lib/dome/ar_pose.dart    ← quality_compute.dart 要 FrameQualityReport
#                                (🔴 与 lib/official_dome/ar_pose.dart 是两个不同文件)
#   🔴 Swift 清单**不变**:PwVioTimebase.swift(1519 行、import ARKit)不镜像 ——
#      台架没有 pocketworld_vio_timebase 通道,PwDeviceMachine.prime() 在台架上如实 null,
#      机型由探针页 sysctlbyname 直读(见该页文件头)。PwZeroArkitGate.swift 也不要:
#      台架没有 ARKit,没有租约可争。
mkdir -p "$B/lib/vio/capture" "$B/lib/vio/quality" "$B/lib/vio/timebase" \
         "$B/lib/quality" "$B/lib/dome" "$B/lib/official_dome" "$B/lib/official_capture"
cp "$P"/lib/vio/capture/*.dart         "$B/lib/vio/capture/"
cp "$P"/lib/vio/quality/*.dart         "$B/lib/vio/quality/"
cp "$P"/lib/vio/timebase/*.dart        "$B/lib/vio/timebase/"
cp "$P"/lib/quality/quality_compute.dart          "$B/lib/quality/"
cp "$P"/lib/dome/ar_pose.dart                     "$B/lib/dome/"
cp "$P"/lib/official_dome/ar_pose.dart            "$B/lib/official_dome/"
cp "$P"/lib/official_capture/metric_rescale.dart  "$B/lib/official_capture/"
# 2026-09-20: 台架现在也编跨端 C++ 传输层(PwXrslamTransportCore.cpp 进了
# Runner 的 Sources)。2026-09-22: 加 PWJSONSafety.swift —— PwCameraSlot 的照片 sidecar 要它。不用拷 —— `$B/vendor/xrslam` 本来就是指向生产那棵树的
# 符号链接,天然逐字节一致。下面那道校验会把这条性质钉住。
# 2026-09-23(对焦三臂 PwFocusArms.swift):镜像范围再跟着依赖走一次。
#   ios/Runner/PwFocusArms.swift
#     → vendor/pw_af/pw_af_c.{h,cpp}(C ABI 门面,经 Runner-Bridging-Header.h 进 Swift)
#         → vendor/pw_af/{af_scan,focus_measure,lens_scale}.{h,cpp}(算法本体)
#   Dart 侧 lib/vio/ffi/pw_focus_ffi.dart 已被 `cp lib/vio/ffi/*.dart` 覆盖。
#   🔴 vendor/pw_af **不能**像 vendor/xrslam 那样做符号链接:xrslam 那个链的是
#      ~/Developer/pocketworld 那棵树,而 pw_af 只存在于本分支 ⇒ 老老实实拷贝,
#      下面那道 cmp 把「逐字节一致」钉住。
# 2026-09-23(录制回放 bench_replay_page.dart):镜像范围再跟着依赖走一次。
#   lib/vio/render/bench_replay_page.dart(render/*.dart 已整目录镜像)
#     → lib/vio/replay/{bench_replay_controller, bench_replay_native}.dart   ← 新目录,整目录镜像
#         → lib/vio/ffi/{xrslam_config, xrslam_live_ffi}.dart、lib/vio/capture/camera_time_offset.dart(已镜像)
#   Dart 走 FFI 到原生:
#     ios/Runner/PwBenchReplay.swift            回放器 + 5 个 pw_bench_replay_* C ABI
#       → PwBenchReplayRecording.swift          录制装载(BasaltVIOBench DeviceRecordingLoader 的移植)
#       → PwBenchReplayScheduler.swift          节拍器(BasaltVIOBench ReplayScheduler 逐字照抄)
#       → PwBenchReplayEngineProbe.{h,c}        只读 BODY_POSE + 求解遥测(桥接头 import;.c 要
#                                               vendor/xrslam/include/XRSLAM.h,HEADER_SEARCH_PATHS 已有)
#       → PwXrslamLive.swift                    ON 臂通路本身(已镜像;回放入口 beginReplay /
#                                               pushReplayImu / 逐帧观察者就加在这个文件里)
#   构建期:ios/scripts/stamp_bench_engine_identity.sh(Runner 的「Stamp Bench Engine Identity」阶段调用,
#     抄生产 ios/scripts/stamp_runtime_identity.sh 的引擎臂那一半)。
#   🔴 pbxproj / Podfile / 桥接头 / main.dart 是台架自己的文件,不在镜像范围(同 PwFocusArms 那次)。
mkdir -p "$B/lib/vio/replay" "$B/ios/scripts"
cp "$P"/lib/vio/replay/*.dart "$B/lib/vio/replay/"
cp "$P"/ios/scripts/stamp_bench_engine_identity.sh "$B/ios/scripts/"
for f in PwCameraSlot.swift PwMonotonicClock.swift PwImuSource.swift PwXrslamLive.swift PWJSONSafety.swift PwFocusArms.swift \
         PwBenchReplay.swift PwBenchReplayRecording.swift PwBenchReplayScheduler.swift \
         PwBenchReplayEngineProbe.h PwBenchReplayEngineProbe.c; do cp "$P/ios/Runner/$f" "$B/ios/Runner/"; done
# 2026-09-23:`$B/vendor/xrslam` 这个符号链接**跟着 P 走**。此前它一直指向 ~/Developer/pocketworld
#   (主检出),而 P 是另一个工作树 —— 下面那道传输层 cmp 之所以一直过,只是因为两边碰巧同版本。
#   逐帧内参之后传输层多了 PushCameraAndRunRawWithIntrinsics,pfk 归档也只在 P 这条线上,
#   指向主检出就既编不过也链不上。现在显式指向 P,下面那道 cmp 照旧把「逐字节一致」钉住。
ln -sfn "$P/vendor/xrslam" "$B/vendor/xrslam"
mkdir -p "$B/vendor/pw_af"
cp "$P"/vendor/pw_af/*.h "$P"/vendor/pw_af/*.cpp "$B/vendor/pw_af/"
cp "$P"/vendor/pw_af/LICENSE.libcamera-BSD-2-Clause "$B/vendor/pw_af/"
# 2026-09-24(合一):bench/unified 里有 4 个「同路径、生产版与台架版不同」的文件(ar_pose.dart、xrslam_config /
#   xrslam_smoke / xrslam_build_contract.dart)。生产路径放的是生产版(完整链要它),台架版原样放在
#   $P/bench/arloopbench_overlay/<同路径>(与 bench/lidar-ruler 的 blob 逐字节相同,见那里的 README.md)。
#   这里在上面整目录拷完之后用台架版覆盖;下面的 cmp 闸对这几个文件比的是 overlay 版。旧真源树没有 overlay 目录 ⇒ 空操作。
OV="$P/bench/arloopbench_overlay"
ov_files="$( [ -d "$OV" ] && cd "$OV" && find . -type f ! -name README.md | sed 's|^\./||' | LC_ALL=C sort || true )"
src_of() { if [ -n "$ov_files" ] && grep -Fxq -- "$1" <<< "$ov_files"; then echo "$OV/$1"; else echo "$P/$1"; fi; }
while IFS= read -r rel; do [ -n "$rel" ] || continue; mkdir -p "$B/$(dirname "$rel")"; cp "$OV/$rel" "$B/$rel"; done <<< "$ov_files"
bad=0
for f in "$B"/lib/vio/ffi/*.dart "$B"/lib/vio/pose/*.dart "$B"/lib/vio/render/*.dart \
         "$B"/lib/vio/capture/*.dart "$B"/lib/vio/quality/*.dart "$B"/lib/vio/timebase/*.dart \
         "$B"/lib/vio/replay/*.dart; do
  rel="lib/vio/${f#*/lib/vio/}"
  cmp -s "$f" "$(src_of "$rel")" || { echo "🔴 不一致: $rel"; bad=1; }
done
for rel in lib/quality/quality_compute.dart lib/dome/ar_pose.dart \
           lib/official_dome/ar_pose.dart lib/official_capture/metric_rescale.dart; do
  cmp -s "$B/$rel" "$(src_of "$rel")" || { echo "🔴 不一致: $rel"; bad=1; }
done
for f in PwCameraSlot.swift PwMonotonicClock.swift PwImuSource.swift PwXrslamLive.swift PWJSONSafety.swift PwFocusArms.swift \
         PwBenchReplay.swift PwBenchReplayRecording.swift PwBenchReplayScheduler.swift \
         PwBenchReplayEngineProbe.h PwBenchReplayEngineProbe.c; do cmp -s "$B/ios/Runner/$f" "$P/ios/Runner/$f" || { echo "🔴 不一致: $f"; bad=1; }; done
cmp -s "$B/ios/scripts/stamp_bench_engine_identity.sh" "$P/ios/scripts/stamp_bench_engine_identity.sh" \
  || { echo "🔴 不一致: ios/scripts/stamp_bench_engine_identity.sh"; bad=1; }
[ "$(readlink "$B/vendor/xrslam")" = "$P/vendor/xrslam" ] \
  || { echo "🔴 vendor/xrslam 没指向真源:$(readlink "$B/vendor/xrslam")"; bad=1; }
for f in "$P"/vendor/pw_af/*.h "$P"/vendor/pw_af/*.cpp "$P"/vendor/pw_af/LICENSE.libcamera-BSD-2-Clause; do
  cmp -s "$B/vendor/pw_af/$(basename "$f")" "$f" || { echo "🔴 不一致: vendor/pw_af/$(basename "$f")"; bad=1; }
done
# 台架的 vendor/pw_af 里不许有生产没有的文件。
for f in "$B"/vendor/pw_af/*; do
  [ -f "$P/vendor/pw_af/$(basename "$f")" ] || { echo "🔴 台架多出生产没有的文件: vendor/pw_af/$(basename "$f")"; bad=1; }
done
for f in PwXrslamTransportCore.h PwXrslamTransportCore.cpp; do cmp -s "$B/vendor/xrslam/transport/$f" "$P/vendor/xrslam/transport/$f" || { echo "🔴 不一致: $f"; bad=1; }; done
# 镜像目录里不许有生产没有的文件(分叉的第一步就是多出一个文件)。
for d in lib/vio/ffi lib/vio/pose lib/vio/render lib/vio/capture lib/vio/quality lib/vio/timebase lib/vio/replay; do
  for f in "$B/$d"/*.dart; do
    [ -f "$P/$d/$(basename "$f")" ] || { echo "🔴 台架多出生产没有的文件: $d/$(basename "$f")"; bad=1; }
  done
done
# ── 2026-09-24(LOD 点云查看器):独立的一段,上面 VIO 段与 P 的默认值一个字不动 ─────────────
#   方案 ~/Developer/pw_lod_data/LOD_ARLOOPBENCH_PLAN_20260924.md §2 L7。真源是**另一棵树**:
#   pocketworld feat/lod-viewer(从 feat/bench-replay 875fe67 切出,永不上生产),所以用自己的变量 L,
#   不借 P。要临时从别的树同步 LOD:PW_BENCH_LOD_SOURCE=<pocketworld 工作树> ./.sync_from_integration.sh
#   只核不拷(给 cmp 闸做阴性对照、或查台架有没有被改过):PW_BENCH_LOD_VERIFY_ONLY=1 ./.sync_from_integration.sh
#   (VIO 段照常跑。)
#   镜像范围 = 下面 lod_scope 一处定义,拷贝与三道闸都用它(逐项说明):
#     lib/point_cloud_lod/*.dart                   桥接 / 相机 / 取景 / 建树编排 / 调试入口页 LodDebugPage
#     lib/ui/official_capture/lod_cloud_view.dart  LOD 页
#     lib/ui/official_capture/cloud_camera.dart    ← lod_camera.dart 与 lod_cloud_view.dart 要它
#                                                  (自包含:只 import dart:math / dart:ui)
#     ios/Runner/PwLodSurface.{h,m} PwLodTexture.swift PwLodTexturePlugin.swift PwLodProbe.swift
#                                                  iOS 外壳(PwLodSurface.h 经台架桥接头 import)
#     vendor/aether_lod/**                         冻结头 + libpw_lod_<sha8>.a + 回执 / 符号表 + build_ios_lod.sh
#   🔴 pbxproj / Podfile / 桥接头 / AppDelegate / main.dart 仍是台架自己的文件,不在镜像范围。
L="${PW_BENCH_LOD_SOURCE:-/Users/kaidongwang/Developer/pw-lod-viewer}"
if [ ! -d "$L" ]; then echo "LOD 源不在，跳过"; else  # 2026-09-24 守卫:真源树已删(分支在 origin/feat/lod-viewer),整段跳过;台架里已镜像的 LOD 文件原样保留
lod_scope="$(
  cd "$L"
  ls lib/point_cloud_lod/*.dart
  for f in lod_cloud_view.dart cloud_camera.dart; do echo "lib/ui/official_capture/$f"; done
  for f in PwLodSurface.h PwLodSurface.m PwLodTexture.swift PwLodTexturePlugin.swift PwLodProbe.swift; do
    echo "ios/Runner/$f"
  done
  find vendor/aether_lod -type f | LC_ALL=C sort
)"
echo "LOD 真源: $L @ $(git -C "$L" rev-parse --short HEAD 2>/dev/null || echo '?')" \
     "(未提交改动 $(git -C "$L" status --porcelain 2>/dev/null | wc -l | tr -d ' ') 个)"
if [ "${PW_BENCH_LOD_VERIFY_ONLY:-0}" != 1 ]; then
  while IFS= read -r rel; do
    mkdir -p "$B/$(dirname "$rel")"
    cp "$L/$rel" "$B/$rel"
  done <<< "$lod_scope"
fi
lbad=0
while IFS= read -r rel; do
  cmp -s "$B/$rel" "$L/$rel" || { echo "🔴 LOD 不一致: $rel"; lbad=1; }
done <<< "$lod_scope"
# 台架 LOD 目录里不许有镜像范围外的文件(分叉的第一步就是多出一个文件)。台架原本没有 lib/ui/,
#   所以整棵 lib/ui 都归 LOD 管;ios/Runner 里只管 PwLod* 这个前缀。点文件也算。
#   🔴 用 here-string 喂 grep,不用管道:grep -q 命中即退出,上游吃 SIGPIPE,pipefail 下会把命中报成没命中。
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  grep -Fxq -- "$rel" <<< "$lod_scope" || { echo "🔴 台架多出 LOD 镜像范围外(真源没有或不该镜像)的文件: $rel"; lbad=1; }
done <<< "$(cd "$B" && { find lib/point_cloud_lod lib/ui vendor/aether_lod -type f 2>/dev/null
                         find ios/Runner -maxdepth 1 -name 'PwLod*' -type f; } | LC_ALL=C sort)"
if [ $lbad -eq 0 ]; then
  echo "✅ LOD 与真源逐字节一致($(printf '%s\n' "$lod_scope" | wc -l | tr -d ' ') 个文件)"
else
  bad=1
fi
fi  # LOD 源存在性守卫结束
# ── 2026-09-24(完整重建链 168):独立的一段,上面 VIO 段(P)与 LOD 段(L)一个字不动 ─────────────
#   真源 = pocketworld 工作树 bench-full-chain-168(分支 bench/full-chain-168):
#     86a45cf = pw-dense-stage 工作树原样快照(1a43510 + 18 个未提交改动 + 未跟踪出货文件,2137 文件逐字节对上);
#     8437faf = 其上唯一一处改动:ios-arm64 PWOfficialSfm 换成 168 包里实际出货的那份核(源码树 vendor 的是 09-08 旧版)。
#   以后的生产补丁(位姿信任标志 / 跟踪会话切分 / 核内图像证据注册 + pwofficial_add_jpeg_frame_v2 / 核内 Sim3+闸 /
#   删 Dart SCALE-ANCHOR / 特征提取 GPU 模糊修复)一律先落在 pocketworld 的分支上,再用本段同步进来。
#   要临时从别的树同步:PW_BENCH_FULL_CHAIN_SOURCE=<pocketworld 工作树> ./.sync_from_integration.sh
#   只核不改(阴性对照 / 查台架有没有被改过):PW_BENCH_FULL_CHAIN_VERIFY_ONLY=1 ./.sync_from_integration.sh
#   镜像方式(逐项说明):
#     pw_full_chain → F                      符号链接。台架 pubspec 的 path 依赖 pocketworld_flutter 指向它:
#                                            生产 lib/ + packages/ + pubspec 原样当一个包用,包名与生产同,
#                                            与台架自己的 lib/vio 镜像(来自 bench-replay)互不相撞。
#     vendor/{aether_ffi,official_sfm,pw_dense,lepton_jpeg} → F/vendor/*    符号链接(同 vendor/xrslam 的做法;
#                                            二进制大,不拷)。Podfile 的三个生产 pod 与 lepton 链接行经它取。
#     ios/Vendor → F/ios/Vendor              符号链接。JXL 静态库/头、Zpaq 源码与许可、NativeCore 许可;
#                                            pbxproj 按生产原样的相对路径(Vendor/...)引用。
#     ios/Runner/<生产原生源文件>            拷贝 + cmp(同上面 VIO 段 Swift 的做法):清单见 fc_runner_files。
#     assets/models/DamagedHelmet.glb、assets/ibl/default_env_ibl.ktx → F/assets/...   符号链接:
#                                            生产代码按根键读的只有这两份(main.dart:875、live_model_view.dart:257)。
#   🔴 vendor/xrslam 仍跟 VIO 段走(bench-replay);168 自己的传输层是它的子集(差异:逐帧内参入口 + 账本),
#      台架只能编一份传输层 ⇒ 完整链的影子 XRSLAM 用 bench-replay 那份。见适配清单。
#   🔴 PWJSONSafety.swift 两段共用:VIO 段从 P 拷,这里只核它与 F 逐字节相同,不一致就报警(不拷,免得两段互相覆盖)。
#   🔴 pbxproj / Podfile / 桥接头 / AppDelegate / main.dart / pubspec 仍是台架自己的文件,不在镜像范围。
F="${PW_BENCH_FULL_CHAIN_SOURCE:-/Users/kaidongwang/.config/superpowers/worktrees/pocketworld/bench-unified-20260924}"
fc_runner_files="AetherTexturePlugin.swift MetalRenderer.swift OfficialAetherARKitPlugin.swift
OfficialArchiveBackgroundTask.swift OfficialReconUmbrella.swift PwARCameraLease.swift PwVioCapability.swift
PwVioSlamFeeder.swift PwVioThermal.swift PwVioTimebase.swift pw_jxl_bridge.h pw_jxl_bridge.mm
pw_zpaq_bridge.h pw_zpaq_bridge.cpp pw_sqlite_descriptor_transform.h pw_sqlite_descriptor_transform.cpp
PrivacyInfo.xcprivacy TestFixtures/test_scene.jpg"
fc_links="pw_full_chain:.
vendor/aether_ffi:vendor/aether_ffi
vendor/official_sfm:vendor/official_sfm
vendor/pw_dense:vendor/pw_dense
vendor/lepton_jpeg:vendor/lepton_jpeg
ios/Vendor:ios/Vendor
assets/models/DamagedHelmet.glb:assets/models/DamagedHelmet.glb
assets/ibl/default_env_ibl.ktx:assets/ibl/default_env_ibl.ktx"
echo "完整链真源: $F @ $(git -C "$F" rev-parse --short HEAD 2>/dev/null || echo '?')" \
     "(未提交改动 $(git -C "$F" status --porcelain 2>/dev/null | wc -l | tr -d ' ') 个)"
if [ "${PW_BENCH_FULL_CHAIN_VERIFY_ONLY:-0}" != 1 ]; then
  for f in $fc_runner_files; do mkdir -p "$B/ios/Runner/$(dirname "$f")"; cp "$F/ios/Runner/$f" "$B/ios/Runner/$f"; done
  while IFS=: read -r dst src; do
    mkdir -p "$B/$(dirname "$dst")"
    if [ "$src" = . ]; then ln -sfn "$F" "$B/$dst"; else ln -sfn "$F/$src" "$B/$dst"; fi
  done <<< "$fc_links"
fi
fbad=0
for f in $fc_runner_files; do cmp -s "$B/ios/Runner/$f" "$F/ios/Runner/$f" || { echo "🔴 完整链不一致: ios/Runner/$f"; fbad=1; }; done
cmp -s "$B/ios/Runner/PWJSONSafety.swift" "$F/ios/Runner/PWJSONSafety.swift" \
  || { echo "🔴 PWJSONSafety.swift:VIO 真源与完整链真源已分叉,台架只能编一份 —— 先在 pocketworld 里对齐"; fbad=1; }
while IFS=: read -r dst src; do
  if [ "$src" = . ]; then want="$F"; else want="$F/$src"; fi
  [ "$(readlink "$B/$dst")" = "$want" ] || { echo "🔴 $dst 没指向完整链真源:$(readlink "$B/$dst")"; fbad=1; }
  [ -e "$B/$dst" ] || { echo "🔴 $dst 不存在或是断链(应指向 $want)"; fbad=1; }
done <<< "$fc_links"
# 真源里 ios/Runner 的生产原生源文件不许有清单外的(漏镜像的第一步就是真源多出一个台架没编的文件)。
#   AppDelegate/SceneDelegate/Info.plist/entitlements/桥接头/GeneratedPluginRegistrant 是台架自己的(对应改法见适配清单);
#   PWJSONSafety.swift 由上面那道 cmp 管。
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  case "$rel" in
    AppDelegate.swift|SceneDelegate.swift|Info.plist|Runner.entitlements|Runner-Bridging-Header.h|PWJSONSafety.swift|GeneratedPluginRegistrant.*) continue;;
    # 2026-09-24(合一):真源是 bench/unified 时 ios/Runner 里还有台架线的文件,归 VIO(P)/ LiDAR(R)/ 合一(U)段管;
    #   PwZeroArkitGate.swift 是台架线文件但有意不镜像(台架没有 ARKit 租约可争,见 VIO 段注释)。
    PwCameraSlot.swift|PwMonotonicClock.swift|PwImuSource.swift|PwXrslamLive.swift|PwFocusArms.swift|PwBenchReplay.swift|PwBenchReplayRecording.swift|PwBenchReplayScheduler.swift|PwBenchReplayEngineProbe.h|PwBenchReplayEngineProbe.c) continue;;
    PwBenchLidarRecordingWriter.swift|PwBenchLidarSession.swift|PwBenchUnifiedPlugin.swift|PwSplatABRunner.swift|PwSplatAB/*|PwZeroArkitGate.swift) continue;;
  esac
  printf '%s\n' $fc_runner_files | grep -Fxq -- "$rel" || { echo "🔴 真源 ios/Runner 多出完整链清单外的文件: $rel"; fbad=1; }
done <<< "$(cd "$F/ios/Runner" && find . -type f ! -path './Assets.xcassets/*' ! -path './Base.lproj/*' | sed 's|^\./||' | LC_ALL=C sort)"
if [ $fbad -eq 0 ]; then
  echo "✅ 完整链与真源逐字节一致($(printf '%s\n' $fc_runner_files | wc -l | tr -d ' ') 个拷贝文件 + $(printf '%s\n' "$fc_links" | wc -l | tr -d ' ') 个符号链接)"
else
  bad=1
fi
# ── 2026-09-24(LiDAR 米尺录制,🔴 bench-only ruler):独立的一段,上面 VIO(P)/ LOD(L)/ 完整链(F)一个字不动 ──
#   🔴 LiDAR 只在台架里当研发期米尺(量 XRSLAM / ARKit 的绝对尺度),永不进产品代码、产品管线、产品提案。
#   真源 = pocketworld 工作树 bench-lidar-ruler-20260924(分支 bench/lidar-ruler,从 feat/bench-replay 875fe67 切出,
#   永不上生产)。用自己的变量 R,不借 P:要临时从别的树同步:PW_BENCH_LIDAR_SOURCE=<pocketworld 工作树> ./.sync_from_integration.sh
#   只核不拷(阴性对照 / 查台架有没有被改过):PW_BENCH_LIDAR_VERIFY_ONLY=1 ./.sync_from_integration.sh
#   镜像范围 = 下面 lidar_scope 一处定义,拷贝与三道闸都用它:
#     lib/bench_lidar/*.dart                        录制页 BenchLidarRecordPage + dart:ffi 绑定
#     ios/Runner/PwBenchLidarRecordingWriter.swift  录制写器(BasaltVIOBench DeviceRecordingWriter @76b8d47 的移植,含深度)
#     ios/Runner/PwBenchLidarSession.swift          ARKit + CoreMotion 会话 + 4 个 @_cdecl pw_bench_lidar_*
#   类型依赖:写器用的是 VIO 段镜像的 ios/Runner/PwBenchReplayRecording.swift 里那套 Codable ⇒ 下面核它与 R 里那份相同。
#   Mac 侧工具(tool/bench/lidar_ruler/、tool/bench/lidar_swift_tests/、tool/bench/pull_lidar_recording.sh)留在 pocketworld。
#   🔴 pbxproj(两份 Swift 进 Runner Sources + 三个配置各 4 条 -Wl,-u,_pw_bench_lidar_*)/ main.dart(const PW_LIDAR_RULER_BENCH
#      分支)是台架自己的文件,不在镜像范围。
R="${PW_BENCH_LIDAR_SOURCE:-/Users/kaidongwang/.config/superpowers/worktrees/pocketworld/bench-unified-20260924}"
if [ ! -d "$R" ]; then echo "LiDAR 尺子源不在,跳过"; else
lidar_scope="$(
  cd "$R"
  ls lib/bench_lidar/*.dart
  for f in PwBenchLidarRecordingWriter.swift PwBenchLidarSession.swift; do echo "ios/Runner/$f"; done
)"
echo "LiDAR 尺子真源: $R @ $(git -C "$R" rev-parse --short HEAD 2>/dev/null || echo '?')" \
     "(未提交改动 $(git -C "$R" status --porcelain 2>/dev/null | wc -l | tr -d ' ') 个)"
if [ "${PW_BENCH_LIDAR_VERIFY_ONLY:-0}" != 1 ]; then
  while IFS= read -r rel; do
    mkdir -p "$B/$(dirname "$rel")"
    cp "$R/$rel" "$B/$rel"
  done <<< "$lidar_scope"
fi
rbad=0
while IFS= read -r rel; do
  cmp -s "$B/$rel" "$R/$rel" || { echo "🔴 LiDAR 尺子不一致: $rel"; rbad=1; }
done <<< "$lidar_scope"
cmp -s "$B/ios/Runner/PwBenchReplayRecording.swift" "$R/ios/Runner/PwBenchReplayRecording.swift" \
  || { echo "🔴 PwBenchReplayRecording.swift:VIO 真源与 LiDAR 真源已分叉,写器与回放装载器会编成两套 Codable —— 先在 pocketworld 里对齐"; rbad=1; }
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  grep -Fxq -- "$rel" <<< "$lidar_scope" || { echo "🔴 台架多出 LiDAR 镜像范围外的文件: $rel"; rbad=1; }
done <<< "$(cd "$B" && { find lib/bench_lidar -type f 2>/dev/null
                         find ios/Runner -maxdepth 1 -name 'PwBenchLidar*' -type f; } | LC_ALL=C sort)"
if [ $rbad -eq 0 ]; then
  echo "✅ LiDAR 尺子与真源逐字节一致($(printf '%s\n' "$lidar_scope" | wc -l | tr -d ' ') 个文件)"
else
  bad=1
fi
fi  # LiDAR 源存在性守卫结束
# ── 2026-09-24(合一:一个台架包 = 全部台架功能):独立的一段,上面 P / L / F / R 段只改了默认真源 ─────────────
#   真源 = pocketworld 工作树 bench-unified-20260924(分支 bench/unified,本地,未推送)。
#   要临时从别的树同步:PW_BENCH_UNIFIED_SOURCE=<pocketworld 工作树> ./.sync_from_integration.sh
#   只核不拷:PW_BENCH_UNIFIED_VERIFY_ONLY=1 ./.sync_from_integration.sh
#   镜像范围 = 下面 unified_scope 一处定义:
#     lib/bench_unified/*.dart           菜单页 / 启动参数路由 / 完整链入口 / 核开关页 / 通道绑定
#     lib/bench_splat/*.dart             泼溅 A/B 页(原 PWSplatAB)
#     ios/Runner/PwBenchUnifiedPlugin.swift   通道 'pw_bench_unified'
#     ios/Runner/PwSplatABRunner.swift        PWSplatAB 外壳 App.swift 的移植
#     ios/Runner/PwSplatAB/*                  bench.mm / bench_points.mm / bench_cloud.mm / wgsl_arms.h 原样 + pw_splat_ab.h
#     vendor/pw_viobench_kit → $U/bench/viobench_kit/dist   符号链接:旧 VIO Replacement Bench 整套(PWVIOBenchKit +
#                                        两个引擎框架),由 bench/viobench_kit/build_kit.sh 编出;下面按 dist/SHA256SUMS.txt 核。
#   🔴 pbxproj(新文件进 Runner Sources、三个框架进 Embed Frameworks)/ AppDelegate / 桥接头 / main.dart 是台架自己的文件。
U="${PW_BENCH_UNIFIED_SOURCE:-/Users/kaidongwang/.config/superpowers/worktrees/pocketworld/bench-unified-20260924}"
if [ ! -d "$U/lib/bench_unified" ]; then echo "合一段真源不在($U),跳过"; else
unified_scope="$(
  cd "$U"
  ls lib/bench_unified/*.dart lib/bench_splat/*.dart
  echo ios/Runner/PwBenchUnifiedPlugin.swift
  echo ios/Runner/PwSplatABRunner.swift
  find ios/Runner/PwSplatAB -type f | LC_ALL=C sort
)"
echo "合一段真源: $U @ $(git -C "$U" rev-parse --short HEAD 2>/dev/null || echo '?')" \
     "(未提交改动 $(git -C "$U" status --porcelain 2>/dev/null | wc -l | tr -d ' ') 个)"
if [ "${PW_BENCH_UNIFIED_VERIFY_ONLY:-0}" != 1 ]; then
  while IFS= read -r rel; do
    mkdir -p "$B/$(dirname "$rel")"
    cp "$U/$rel" "$B/$rel"
  done <<< "$unified_scope"
  ln -sfn "$U/bench/viobench_kit/dist" "$B/vendor/pw_viobench_kit"
fi
ubad=0
while IFS= read -r rel; do
  cmp -s "$B/$rel" "$U/$rel" || { echo "🔴 合一段不一致: $rel"; ubad=1; }
done <<< "$unified_scope"
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  grep -Fxq -- "$rel" <<< "$unified_scope" || { echo "🔴 台架多出合一段镜像范围外的文件: $rel"; ubad=1; }
done <<< "$(cd "$B" && { find lib/bench_unified lib/bench_splat ios/Runner/PwSplatAB -type f 2>/dev/null
                         find ios/Runner -maxdepth 1 \( -name 'PwBenchUnified*' -o -name 'PwSplatAB*' \) -type f; } | LC_ALL=C sort)"
[ "$(readlink "$B/vendor/pw_viobench_kit")" = "$U/bench/viobench_kit/dist" ] \
  || { echo "🔴 vendor/pw_viobench_kit 没指向 $U/bench/viobench_kit/dist:$(readlink "$B/vendor/pw_viobench_kit")"; ubad=1; }
if [ -f "$U/bench/viobench_kit/dist/SHA256SUMS.txt" ]; then
  ( cd "$U/bench/viobench_kit/dist" && grep -v ' \./SHA256SUMS.txt$' SHA256SUMS.txt | shasum -a 256 -c --quiet ) \
    || { echo "🔴 viobench_kit/dist 与它的 SHA256SUMS.txt 不符"; ubad=1; }
  for e in PWXRSLAMEngine PWBasaltEngine; do
    cmp -s "$U/bench/viobench_kit/dist/$e.framework/$e" "$U/bench/viobench_kit/engines/$e.framework/$e" \
      || { echo "🔴 dist 里的 $e 不是 engines/ 里入库的那份"; ubad=1; }
  done
else
  echo "🔴 旧 VIO 台架框架还没编:先跑 $U/bench/viobench_kit/build_kit.sh"; ubad=1
fi
if [ $ubad -eq 0 ]; then
  echo "✅ 合一段与真源逐字节一致($(printf '%s\n' "$unified_scope" | wc -l | tr -d ' ') 个文件 + viobench_kit/dist 符号链接)"
else
  bad=1
fi
fi  # 合一段真源存在性守卫结束
[ $bad -eq 0 ] && echo "✅ 与生产逐字节一致"
exit $bad
