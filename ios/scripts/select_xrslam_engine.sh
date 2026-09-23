#!/bin/sh
# 选择 XRSLAM 引擎臂,并**保证下一次构建真的重链**。
#
#   ios/scripts/select_xrslam_engine.sh generic
#   ios/scripts/select_xrslam_engine.sh gpufenothread -- flutter build ios --release --no-codesign
#
# 为什么需要这个脚本而不是光 `export PW_XRSLAM_ENGINE=…`:
#   ios/Podfile 只在 **pod install 跑的时候**被求值,而 flutter 只在
#   Podfile 比 Podfile.lock 新(或插件清单变了)时才跑 pod install。
#   光改环境变量不动 Podfile ⇒ pod install 不跑 ⇒ xcconfig 里还是上一条臂,
#   构建「看起来换了其实没换」。这里 touch 一下 Podfile 把那一步逼出来。
#
# 就算绕过本脚本直接设环境变量,也不会静默跑错臂:
#   ios/scripts/stamp_runtime_identity.sh 会把 PW_XRSLAM_ENGINE(请求)与
#   PW_XRSLAM_LINKED_ENGINE(xcconfig 里的实际结果)对账,对不上直接构建失败;
#   Release 下还会在产物二进制里核对该臂的指纹字符串在场、另一条臂不在场。
set -eu

engine="${1:-}"
case "$engine" in
  generic|gpufenothread|gpufenothread_pfk) ;;
  *)
    echo "用法: $0 <generic|gpufenothread|gpufenothread_pfk> [-- 命令...]" >&2
    echo "  generic           出货档 libxrslam_generic_4beb1a9.a(默认)" >&2
    echo "  gpufenothread     研究臂 libxrslam_gpufenothread_b9b14814.a(GPU 前端 ON + 线程化 OFF)" >&2
    echo "  gpufenothread_pfk 研究臂 libxrslam_gpufenothread_pfk_6f6aa21c.a(上一档 + 逐帧内参,fork 04c0e83)" >&2
    exit 64
    ;;
esac
shift

ios_dir="$(cd "$(dirname "$0")/.." && pwd)"
/usr/bin/touch "$ios_dir/Podfile"

PW_XRSLAM_ENGINE="$engine"
export PW_XRSLAM_ENGINE
echo "PW_XRSLAM_ENGINE=$engine(已 touch $ios_dir/Podfile,下次构建会重跑 pod install)"

if [ "${1:-}" = "--" ]; then
  shift
  [ "$#" -gt 0 ] || { echo "error: -- 后面没有命令" >&2; exit 64; }
  exec "$@"
fi
