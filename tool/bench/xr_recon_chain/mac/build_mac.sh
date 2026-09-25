#!/bin/bash
# build_mac.sh <name> <THR ON|OFF>
# [xrchain 2026-09-25] 照抄 preint/tools/build_mac.sh,只换 W 与回放器源;原注:[preint 2026-09-25] 配方逐项照抄 scratchpad/bkpose/tools/build_mac.sh(= wobble/build_mac.sh = scaleS2
# build_variant.sh = xrslam pw_tools/regression/build_pc_headless.sh @04c0e83):LOWLATENCY ON、队列上界 0、
# 生产编译旗标 -ffp-contract=off -fno-fast-math。只换源码树(preint/xrslam-wt)/构建/输出路径;
# 回放器一律带 -DPW_BKPOSE_TAP(8ebac9a 起引擎有后端位姿出口)。THR 两档各用各的构建目录。
set -euo pipefail
SP=/private/tmp/claude-501/-Users-kaidongwang-Documents-progecttwo/2359d42b-b338-4098-99ad-6a4c217067ad/scratchpad
W=$SP/xrchain; X=$W/xrslam-wt
NAME="$1"; THR="$2"; LL=ON
B=$W/build-mac-thr$THR; OUT=$W/v/$NAME
D=$HOME/Developer/xrslam-deps-tarballs
STUBS=$SP/scaleS3/stubs
OCV=/opt/homebrew/lib/cmake/opencv5
OCV_INC=/opt/homebrew/opt/opencv/include/opencv5
OCV_LIB=/opt/homebrew/opt/opencv/lib
CXXFLAGS="-ffp-contract=off -fno-fast-math -fchar8_t -Dceres=pw_xrslam_ceres_1_14"
CXXFLAGS="$CXXFLAGS -DXRSLAM_FEATURE_TRACKER_QUEUE_CAPACITY=0 -DXRSLAM_FRONTEND_QUEUE_CAPACITY=0"
SHIM="$B.ocv_shim"; mkdir -p "$SHIM/opencv2/calib3d"
cat > "$SHIM/opencv2/calib3d/calib3d_c.h" <<'H'
#ifndef PW_CALIB3D_C_SHIM_H
#define PW_CALIB3D_C_SHIM_H
#include <opencv2/calib3d.hpp>
#ifndef CV_EPNP
#define CV_EPNP cv::SOLVEPNP_EPNP
#endif
#endif
H
CXXFLAGS="$CXXFLAGS -I$SHIM"
rm -f "$X/lib/libxrslam.dylib"
cmake -S "$X" -B "$B" -G Ninja \
  -D CMAKE_BUILD_TYPE=Release -D CMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -D XRSLAM_ENABLE_THREADING=$THR -D XRSLAM_LOWLATENCY_POSE=$LL \
  -D SUITESPARSE=OFF -D CXSPARSE=OFF -D EIGENSPARSE=ON \
  -D CMAKE_CXX_FLAGS="$CXXFLAGS" \
  -D OpenCV_DIR="$OCV" \
  -D FETCHCONTENT_SOURCE_DIR_DEPENDS-EIGEN="$D/eigen-3.3.7" \
  -D FETCHCONTENT_SOURCE_DIR_DEPENDS-CERES-SOLVER="$D/ceres_pinned" \
  -D FETCHCONTENT_SOURCE_DIR_DEPENDS-SPDLOG="$D/spdlog" \
  -D FETCHCONTENT_SOURCE_DIR_DEPENDS-YAML-CPP="$D/yamlcpp" \
  -D FETCHCONTENT_SOURCE_DIR_DEPENDS-ARGPARSE="$STUBS/argparse" \
  -D FETCHCONTENT_SOURCE_DIR_DEPENDS-LITEVIZ="$STUBS/liteviz" \
  -D FETCHCONTENT_FULLY_DISCONNECTED=ON > "$B.configure.log" 2>&1 \
  || { echo "configure FAIL $B.configure.log"; tail -30 "$B.configure.log"; exit 1; }
ninja -C "$B" -j "${JOBS:-4}" xrslam > "$B.build.$NAME.log" 2>&1 \
  || { echo "build FAIL $B.build.$NAME.log"; tail -40 "$B.build.$NAME.log"; exit 1; }
mkdir -p "$OUT"; cp "$X/lib/libxrslam.dylib" "$OUT/"
install_name_tool -id "@rpath/libxrslam.dylib" "$OUT/libxrslam.dylib" 2>/dev/null || true
IO="$X/xrslam-pc/player/src/IO"
# [xrchain] 台架链路核心(与手机同一份源码);RUNNER_DEFS 带 -DPW_XRCHAIN 时编进回放器
CHAIN_DIR=${CHAIN_DIR:-$HOME/.config/superpowers/worktrees/pocketworld/bench-xr-recon-chain-20260925/vendor/xrslam/chain}
CHAIN_SRC=""; case " ${RUNNER_DEFS:-} " in *" -DPW_XRCHAIN "*) CHAIN_SRC="$CHAIN_DIR/PwXrReconChainCore.cpp -I$CHAIN_DIR";; esac
c++ -std=c++17 -O2 $CXXFLAGS -DPW_BKPOSE_TAP ${RUNNER_DEFS:-} -o "$OUT/pwvi_runner" \
  "${RUNNER_SRC:-$W/tools/pwvi_runner.cpp}" $CHAIN_SRC "$IO/dataset_reader.cpp" "$IO/euroc_dataset_reader.cpp" \
  "$IO/async_dataset_reader.cpp" "$IO/tum_dataset_reader.cpp" \
  -I"$X/xrslam-interface/include" -I"$IO" -I"$X/xrslam-pc/player/src" \
  -I"$X/xrslam-extra/include" -I"$X/xrslam/include" -I"$B/xrslam/include" \
  -I"$D/eigen-3.3.7" -I"$D/yamlcpp/include" -I"$OCV_INC" \
  -L"$OUT" -lxrslam \
  -L"$OCV_LIB" -lopencv_core -lopencv_imgcodecs -lopencv_imgproc \
  -Wl,-rpath,"$OUT" -Wl,-rpath,"$OCV_LIB"
grep -n "XRSLAM_IOS\|THREADING\|LOWLATENCY" "$B/xrslam/include/xrslam/version.h" || true
echo "BUILD_OK $NAME thr=$THR src=$(git -C "$X" rev-parse --short HEAD) dirty=$(git -C "$X" status --porcelain | wc -l | tr -d ' ')"
shasum -a 256 "$OUT/libxrslam.dylib" "$OUT/pwvi_runner"
