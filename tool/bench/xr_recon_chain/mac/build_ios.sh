#!/bin/bash
# build_ios.sh <lowlatency ON|OFF> <out.a>   [xrchain 2026-09-25] 照抄 preint/tools/build_ios.sh,只换 W;原注:[preint 2026-09-25] 照抄 scratchpad/bkpose/tools/build_ios.sh(= xrofficial 89042cd5 的配方),只换 W 路径
# iOS arm64 archive of the official-config arm. Recipe = ~/Developer/viobench-build/gpufe/build_gpufe_nothread.sh
# (the recipe of the bench's pfk arm, same lineage 04c0e83) with exactly these changes:
#   XRSLAM_GPU_FRONTEND        ON  -> (not passed = OFF)        official: CPU/OpenCV front end
#   XRSLAM_ENABLE_THREADING    OFF -> ON                        official iOS
#   XRSLAM_LOWLATENCY_POSE     (n/a) -> $1                      official iOS rules (renamed from XRSLAM_IOS)
#   queue capacities           2/4 -> 0 (= upstream unbounded)  official
# XRSLAM_IOS stays OFF (config passed as file paths; no iOS packaging). Same build dir for ON and the
# OFF control so the member-by-member attribution diff is path-clean.
set -euo pipefail
W=/private/tmp/claude-501/-Users-kaidongwang-Documents-progecttwo/2359d42b-b338-4098-99ad-6a4c217067ad/scratchpad/xrchain
X=$W/xrslam-wt; B=$W/build-ios; DEPS=$HOME/Developer/xrslam-deps-tarballs
LL="$1"; OUT="$2"; JOBS=${JOBS:-6}
CXXFLAGS="-ffp-contract=off -fno-fast-math -fchar8_t -Dceres=pw_xrslam_ceres_1_14 -DXRSLAM_FEATURE_TRACKER_QUEUE_CAPACITY=0 -DXRSLAM_FRONTEND_QUEUE_CAPACITY=0"
cmake -S "$X" -B "$B" -G Ninja \
  -D CMAKE_MAKE_PROGRAM="$(command -v ninja)" \
  -D CMAKE_TOOLCHAIN_FILE="$X/cmake/Modules/Platform/ios.toolchain.cmake" \
  -D CMAKE_BUILD_TYPE=Release \
  -D IOS_PLATFORM=OS64 -D IOS_ARCH=arm64 -D IOS_DEPLOYMENT_TARGET=14.0 \
  -D ENABLE_BITCODE=0 -D ENABLE_ARC=1 -D ENABLE_VISIBILITY=0 \
  -D CMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -D XRSLAM_IOS_OVERRIDE=1 \
  -D XRSLAM_THREADING_OVERRIDE=1 -D XRSLAM_ENABLE_THREADING=ON \
  -D XRSLAM_LOWLATENCY_POSE=$LL \
  -D CMAKE_CXX_FLAGS="$CXXFLAGS" \
  -D FETCHCONTENT_SOURCE_DIR_DEPENDS-EIGEN="$DEPS/eigen-3.3.7" \
  -D FETCHCONTENT_SOURCE_DIR_DEPENDS-OPENCV="$DEPS/opencv-4.0.1-ios-framework/opencv2.framework" \
  -D FETCHCONTENT_FULLY_DISCONNECTED=OFF > "$B.configure.$LL.log" 2>&1 \
  || { echo "configure FAIL $B.configure.$LL.log" >&2; tail -20 "$B.configure.$LL.log" >&2; exit 1; }
grep -n "XRSLAM_IOS\b\|XRSLAM_ENABLE_THREADING\|XRSLAM_LOWLATENCY" "$B/xrslam/include/xrslam/version.h"
ninja -C "$B" -j "$JOBS" xrslam-core xrslam-extra-opencv-image xrslam-extra-yaml-config yaml-cpp > "$B.build.$LL.log" 2>&1 \
  || { echo "build FAIL" >&2; tail -30 "$B.build.$LL.log" >&2; exit 1; }
for t in xrslam-interface/CMakeFiles/xrslam.dir/src/XRSLAMInternal.cpp.o \
         xrslam-interface/CMakeFiles/xrslam.dir/src/XRSLAMManager.cpp.o \
         xrslam-localization/CMakeFiles/xrslam-localization.dir/src/XRGlobalLocalizerInternal.cpp.o \
         xrslam-localization/CMakeFiles/xrslam-localization.dir/src/XRGlobalLocalizerManager.cpp.o; do
  ninja -C "$B" -j "$JOBS" "$t" >> "$B.build.$LL.log" 2>&1
done
OBJS=$(find "$B/xrslam-interface/CMakeFiles" "$B/xrslam-localization/CMakeFiles" -name "*.cpp.o" | sort)
rm -f "$OUT"
xcrun libtool -static -D -no_warning_for_no_symbols -o "$OUT" \
  "$B/xrslam/libxrslam-core.a" "$B/xrslam-extra/libxrslam-extra-opencv-image.a" \
  "$B/xrslam-extra/libxrslam-extra-yaml-config.a" "$B/_deps/depends-yaml-cpp-build/libyaml-cpp.a" \
  $OBJS
python3 - "$OUT" <<'NORM'
import sys
path=sys.argv[1]; d=bytearray(open(path,'rb').read()); assert d[:8]==b'!<arch>\n'
p=8; n=0
while p+60<=len(d):
    hdr=d[p:p+60]; assert hdr[58:60]==b'`\n'
    size=int(bytes(hdr[48:58]).decode().strip())
    d[p+16:p+28]=b'0'.ljust(12); d[p+28:p+34]=b'0'.ljust(6); d[p+34:p+40]=b'0'.ljust(6)
    n+=1; p+=60+size
    if p%2: p+=1
open(path,'wb').write(bytes(d)); print('normalized members', n)
NORM
xcrun nm -g --defined-only "$OUT" > "${OUT}.syms.txt" 2>/dev/null || true
miss=0
for s in XRSLAMCreate XRSLAMDestroy XRSLAMGetResult XRSLAMPushSensorData XRSLAMRunOneFrame; do
  if grep -qE "T _${s}$" "${OUT}.syms.txt"; then echo "  ok $s"; else echo "  MISSING $s"; miss=1; fi
done
[ "$miss" -eq 0 ] || { echo "ABI incomplete" >&2; exit 1; }
echo "members $(xcrun ar -t "$OUT" | grep -c '\.o$')  sha256 $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
echo IOS_BUILD_DONE
