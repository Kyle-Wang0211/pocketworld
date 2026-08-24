#!/bin/zsh
# [pw] C API 契约测试的复跑脚本。/tmp 会被系统清空,所以源码留在 progecttwo。
# 用法: zsh RUN.sh <build目录名>            默认口径 (build-v1)
#       zsh RUN.sh <build目录名> text 1     移动端口径 (CONFIG_FROM_STRING + THREADING)
# 内存铁律:任何 ninja/cmake 构建都显式 -j 3,禁止裸 -j。
set -u
R=/Users/kaidongwang/Developer/xrslam
B=${1:-build-v1}; MODE=${2:-}; THR=${3:-0}
D=$(cd "$(dirname "$0")" && pwd)
cd "$R" || exit 1
cmake --build "$B" -j 3 || exit 1
cc -std=c11 -Wall -Wextra -Wstrict-prototypes -pedantic -O0 -g \
   -Ixrslam-interface/include "$D/pw_api_test.c" -o "$D/pw_api_test" \
   "$B/xrslam-interface/libxrslam.dylib" -lm \
   -Wl,-rpath,"$R/$B/xrslam-interface" || exit 1
"$D/pw_api_test" configs/iphone_slam.yaml configs/iphonex.yaml "$THR" $MODE
