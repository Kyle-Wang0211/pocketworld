#!/bin/bash
# build_xr_propagate2_ref.sh —— [xrchain] 外推对照工具的参照构建。源码 = offline_sfm/tools/xr_propagate2.cc 逐字节拷贝
# (它原样 #include preint/xrslam-wt@4e8dda2 的 detail.cpp,调用引擎自己的 propagate_state_okvis2);
# 旗标 / 包含路径逐字取自 offline_sfm/tools/build_xr_propagate2.sh。唯一不同:那份脚本链的 build/xrlib2 已不在,
# 这里链 preint/v/okvis_state_nothr/libxrslam.dylib(4e8dda2 单线程构建,只取 YamlConfig)。不碰对方文件。
set -euo pipefail
SP=/private/tmp/claude-501/-Users-kaidongwang-Documents-progecttwo/2359d42b-b338-4098-99ad-6a4c217067ad/scratchpad
O=$SP/offline_sfm; X=$SP/preint/xrslam-wt; B=$SP/preint/build-mac-thrOFF; D=$HOME/Developer/xrslam-deps-tarballs
OUT=$SP/xrchain/v/xrprop_ref; mkdir -p $OUT
cp $O/tools/xr_propagate2.cc $OUT/xr_propagate2.cc; cmp $O/tools/xr_propagate2.cc $OUT/xr_propagate2.cc
cp $SP/preint/v/okvis_state_nothr/libxrslam.dylib $OUT/
FLAGS=(-ffp-contract=off -fno-fast-math -fchar8_t -Dceres=pw_xrslam_ceres_1_14 -DXRSLAM_FEATURE_TRACKER_QUEUE_CAPACITY=0
       -DXRSLAM_FRONTEND_QUEUE_CAPACITY=0 -I$SP/preint/build-mac-thrOFF.ocv_shim -O3 -DNDEBUG -std=gnu++17 -arch arm64
       -Qunused-arguments -mllvm -inline-threshold=5000)
INC=(-I$X/xrslam/include -I$B/xrslam/include -I$X/xrslam/src -I$X/xrslam-extra/include -I$D/spdlog/include
     -I$D/yamlcpp/include -isystem $D/eigen-3.3.7 -isystem $B/_deps/depends-ceres-solver-build/config
     -isystem $D/ceres_pinned/internal/ceres/miniglog -isystem $D/ceres_pinned/include
     -isystem /opt/homebrew/Cellar/opencv/5.0.0_5/include/opencv5)
c++ "${FLAGS[@]}" "${INC[@]}" $OUT/xr_propagate2.cc -L$OUT -lxrslam \
   -Wl,-rpath,$OUT -Wl,-rpath,/opt/homebrew/opt/opencv/lib -o $OUT/xr_propagate2
git -C $X rev-parse --short HEAD; git -C $X status --porcelain | wc -l
shasum -a 256 $OUT/xr_propagate2 $OUT/libxrslam.dylib
