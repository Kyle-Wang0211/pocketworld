#!/bin/sh
#
# build_ios_lod.sh —— LOD 查看器 iOS 小库 libpw_lod_<sha8>.a 的构建 + 校验(方案 §3a 选项 A1)。
#
# ══ 这份库是什么 ═══════════════════════════════════════════════════════════════
# Aether3D 引擎仓 aether_cpp 的四块纯 C++ 源码编成的 iOS arm64 静态库:
#   pointcloud_lod(选择/流式/控制器)+ pointcloud_lod_build(PR #100 手机建树)
#   + pointcloud_lod_render(渲染 pass、冻结 C 接口 pwlod_viewer.h、B1 渲染线程)
#   + m1_bench/pw_lod_bench.cpp(pwlod_run,台架原文件逐字节)。
# **不含 Dawn**:所有 wgpu* 都是未定义符号,由 App 里已有的那份 Dawn 绑定
# (台架:Release Dawn 以普通归档链入;产品功能分支:ffi 自带的那份)。
# 编译用的 webgpu.h 就是本目录 include/dawn/webgpu.h(sha256 6d632738…)。
#
# ══ 纪律(照 vendor/xrslam/build_ios_generic.sh 头注释)══════════════════════════
# · --verify-only(默认)把出货件钉死:归档 sha、成员清单 sha、成员名与顺序、
#   导出符号表与 .syms.txt 一致、已定义的 wgpu* 必须为 0、每个未定义的 wgpu*
#   都在钉死的 webgpu.h 里声明过、C 接口 18 个入口都在、版本串 "<sha8> abi=<N>"、随附头文件 sha、
#   回执与脚本常量一致。**所有检查都跑完再给结论**,失败项逐条列出。
# · --build 只往一个**新的**暂存目录里编(PW_LOD_IOS_WORK_ROOT),不碰出货件;
#   --install 只在出货位置还没有产物时才拷进来(不覆盖)。
# · 与 xrslam 不同:这份**可以**逐字节复现 —— 源码取自引擎仓一个固定提交
#   (git archive,天然干净)、归档头归零(ZERO_AR_DATE=1 + libtool -D)、
#   路径前缀映射掉(-ffile-prefix-map)。实测两个不同暂存目录各编一次,
#   产物 sha256 相同(见回执 reproducibility)。
# · 🔴 不要用 `nm | grep -q`:grep 命中即退出,nm 吃 SIGPIPE,pipefail 下会把
#   成功的检查报成失败(xrslam 脚本里记下的教训)。一律先落盘再 grep。
#
# 用法:
#   ./build_ios_lod.sh                      # = --verify-only
#   ./build_ios_lod.sh --verify-only
#   PW_LOD_ARTIFACT=/path/x.a ./build_ios_lod.sh --verify-only   # 校验别的归档(阴性对照用)
#   ./build_ios_lod.sh --manifest           # 打印出货件成员清单
#   PW_LOD_IOS_WORK_ROOT=/private/tmp/pw-lod-ios-<tag> \
#     ./build_ios_lod.sh --build <Aether3D 仓路径>        # 编到暂存目录
#   ./build_ios_lod.sh --install <暂存目录>              # 暂存产物 → libs/ios-arm64/(不覆盖)

set -eu

engine_repository="https://github.com/Kyle-Wang0211/Aether3D"
engine_revision="afb521e6730e8f3539235fb9c4ba215b685c5623"
engine_branch="feat/pointcloud-lod-viewer"
sha8="afb521e6"
abi_version="2"   # PWLOD_ABI_VERSION of the frozen header; pwlod_version() = "<sha8> abi=<this>"
minimum_ios="15.0"
source_date_epoch="1700000000"
expected_clang_version="Apple clang version 17.0.0 (clang-1700.6.3.2)"
expected_sdk_version="26.2"

# 出货件(2026-09-24 从引擎 afb521e6 = ABI v2、lowest_spacing 按 Potree 构建;两个暂存目录各编一次逐字节相同)
expected_artifact_sha256="55f72ada62617a0f27751155f6f6be1b4fd31f613f2681c71cb0ffd0a28fbc1e"
expected_member_manifest_sha256="f9f7f9a60253e6b951ff09f2694bbd895ef077a175503337d9a174ca6f019568"
expected_syms_sha256="6d248a6520da46ea56e2de00e58b0e88744baee3a51f50c51b360440f0d0eafb"
expected_members="octree.o select.o stream.o build.o chunker_countsort.o indexer.o writer.o ply_source.o lod_render.o pwlod_viewer.o pwlod_build.o pw_lod_bench.o"
expected_member_count="12"

# 随附头文件与许可原文
pwlod_viewer_h_sha256="4b047f1fb56ae1575fc5fae5777ef9ea8acdff536ff93a89265550595e51837c"   # ABI v2 (comment fix: lowest_spacing per Potree)
pw_lod_bench_h_sha256="d5a349a2dfd0721a19a5fb345515ddcd8b85b1143d8b19a95e753edebfaf780e"
dawn_webgpu_h_sha256="6d632738597019d062a5a24b30cecb8f83811dd72bc204c321081d46843b0257"
webgpu_shell_h_sha256="5316d9fd241e604b3260fa8d4398a458a3dc88ee69c540ac959260b444bdfae3"
dawn_license_sha256="e2908f7576fb12be5bdb8480cddb0be62badb498cadb821d043aeaf01b0b0899"
dawn_revision="12ee391c7411285895f4289a3d889a182c093014"

expected_abi="pwlod_gpu_create pwlod_gpu_destroy pwlod_params_default pwlod_viewer_create pwlod_viewer_load_octree pwlod_viewer_set_params pwlod_viewer_set_camera pwlod_viewer_set_targets pwlod_viewer_start pwlod_viewer_acquire_latest pwlod_viewer_stop pwlod_viewer_get_stats pwlod_viewer_render_once pwlod_viewer_destroy pwlod_build_from_ply pwlod_verify_octree pwlod_version pwlod_run"

# 源码(相对 aether_cpp/),顺序 = 归档成员顺序
sources="src/pointcloud_lod/octree.cpp src/pointcloud_lod/select.cpp src/pointcloud_lod/stream.cpp src/pointcloud_lod_build/build.cpp src/pointcloud_lod_build/chunker_countsort.cpp src/pointcloud_lod_build/indexer.cpp src/pointcloud_lod_build/writer.cpp src/pointcloud_lod_build/ply_source.cpp src/pointcloud_lod_render/lod_render.cpp src/pointcloud_lod_render/pwlod_viewer.cpp src/pointcloud_lod_render/pwlod_build.cpp src/pointcloud_lod_render/m1_bench/pw_lod_bench.cpp"

# 仓 CMake 的 AETHER_STRICT_COMPILE_OPTIONS + CMAKE_CXX_STANDARD 20 + Release(-O3 -DNDEBUG)
compile_flags="-std=c++20 -O3 -DNDEBUG -ffp-contract=off -fno-fast-math -Wall -Wextra -Werror -fno-exceptions -fno-rtti"
forbidden_flags="-ffast-math"

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
artifact_name="libpw_lod_${sha8}.a"
shipped="$script_dir/libs/ios-arm64/$artifact_name"
artifact="${PW_LOD_ARTIFACT:-$shipped}"

hash_file() { shasum -a 256 "$1" | awk '{print $1}'; }

member_manifest() {
  tmp="$(mktemp -d)"
  ( cd "$tmp" && ar -x "$1" )
  ar -t "$1" | while IFS= read -r m; do
    case "$m" in __.SYMDEF*) continue ;; esac
    [ -f "$tmp/$m" ] && printf '%s  %s\n' "$(hash_file "$tmp/$m")" "$m"
  done
  rm -rf "$tmp"
}

member_names() { ar -t "$1" | grep -v '^__\.SYMDEF' | tr '\n' ' ' | sed 's/ $//'; }

# nm 的归档成员头 "path/lib.a(member.o):" 归一成 "member.o:",与归档文件名/路径无关
defined_syms() { nm -g --defined-only "$1" 2>/dev/null | sed 's/^.*(\(.*\)):$/\1:/'; }

fails=0
fail() { echo "  FAIL $*" >&2; fails=$((fails + 1)); }
ok() { echo "  ok   $*"; }

check_hash() {  # label file expected
  [ -f "$2" ] || { fail "$1: missing $2"; return; }
  a="$(hash_file "$2")"
  if [ "$a" = "$3" ]; then ok "$1 sha256=$a"; else fail "$1: expected $3 actual $a"; fi
}

check_archive() {  # archive syms_file
  a="$1"
  n="$(member_names "$a" | wc -w | tr -d ' ')"
  [ "$n" = "$expected_member_count" ] && ok "member count $n" || fail "member count: expected $expected_member_count actual $n"
  names="$(member_names "$a")"
  [ "$names" = "$expected_members" ] && ok "member names/order" || fail "member names/order: $names"
  mf="$(mktemp)"; member_manifest "$a" > "$mf"; m="$(hash_file "$mf")"; rm -f "$mf"
  [ "$m" = "$expected_member_manifest_sha256" ] && ok "member manifest $m" || fail "member manifest: expected $expected_member_manifest_sha256 actual $m"
  syms="$(mktemp)"; defined_syms "$a" > "$syms"
  s="$(hash_file "$syms")"
  [ "$s" = "$expected_syms_sha256" ] && ok "defined-symbol table $s" || fail "defined-symbol table: expected $expected_syms_sha256 actual $s"
  if [ -n "${2:-}" ]; then
    if [ -f "$2" ] && cmp -s "$syms" "$2"; then ok ".syms.txt matches nm"; else fail ".syms.txt does not match nm of the archive"; fi
  fi
  dw="$(awk 'NF==3 && $3 ~ /^_wgpu/' "$syms" | wc -l | tr -d ' ')"
  if [ "$dw" = "0" ]; then ok "defined wgpu* = 0 (no Dawn inside)"; else
    fail "defined wgpu* = $dw (must be 0; Dawn object inside?):"
    awk 'NF==3 && $3 ~ /^_wgpu/ {print "       " $3}' "$syms" | head -5 >&2
  fi
  for sym in $expected_abi; do
    if grep -Eq " T _$sym\$" "$syms"; then :; else fail "missing exported symbol $sym"; fi
  done
  ok "C ABI + pwlod_run: $(echo $expected_abi | wc -w | tr -d ' ') entry points checked"
  strs="$(mktemp)"; strings -a "$a" > "$strs" 2>/dev/null
  if grep -Fxq "$sha8 abi=$abi_version" "$strs"; then ok "pwlod_version string \"$sha8 abi=$abi_version\""; else
    fail "pwlod_version string \"$sha8 abi=$abi_version\" not in the archive"; fi
  rm -f "$strs"
  und="$(mktemp)"
  nm -g -u "$a" 2>/dev/null | awk '$1 ~ /^_wgpu/ {print substr($1,2)} $2 ~ /^_wgpu/ {print substr($2,2)}' | sort -u > "$und"
  nu="$(wc -l < "$und" | tr -d ' ')"
  miss=0
  while IFS= read -r f; do
    grep -q "WGPU_EXPORT .* $f(" "$script_dir/include/dawn/webgpu.h" || { miss=$((miss + 1)); echo "       undeclared: $f" >&2; }
  done < "$und"
  [ "$miss" = "0" ] && ok "undefined wgpu* = $nu, all declared in include/dawn/webgpu.h" || fail "$miss undefined wgpu* not in the pinned webgpu.h"
  rm -f "$syms" "$und"
}

check_headers() {
  check_hash "include/pwlod_viewer.h (frozen ABI)" "$script_dir/include/pwlod_viewer.h" "$pwlod_viewer_h_sha256"
  check_hash "include/pw_lod_bench.h" "$script_dir/include/pw_lod_bench.h" "$pw_lod_bench_h_sha256"
  check_hash "include/dawn/webgpu.h" "$script_dir/include/dawn/webgpu.h" "$dawn_webgpu_h_sha256"
  check_hash "include/webgpu/webgpu.h" "$script_dir/include/webgpu/webgpu.h" "$webgpu_shell_h_sha256"
  check_hash "include/dawn/LICENSE" "$script_dir/include/dawn/LICENSE" "$dawn_license_sha256"
}

check_receipt() {
  r="$script_dir/libs/ios-arm64/$artifact_name.receipt.json"
  [ -f "$r" ] || { fail "receipt missing: $r"; return; }
  if python3 - "$r" "$expected_artifact_sha256" "$expected_member_manifest_sha256" "$expected_syms_sha256" "$engine_revision" "$expected_member_count" "$(hash_file "$0")" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
want = {"artifact_sha256": sys.argv[2], "archive_member_manifest_sha256": sys.argv[3],
        "syms_sha256": sys.argv[4], "engine_revision": sys.argv[5], "archive_member_count": int(sys.argv[6]),
        "build_script_sha256": sys.argv[7]}
bad = [k for k, v in want.items() if r.get(k) != v]
if bad:
    print("       receipt disagrees with script on: " + ", ".join(bad), file=sys.stderr)
    sys.exit(1)
PY
  then ok "receipt agrees with script constants"; else fail "receipt disagrees with script constants"; fi
}

verify_toolchain() {
  c="$(xcrun --sdk iphoneos clang --version | head -1)"
  [ "$c" = "$expected_clang_version" ] || { echo "clang mismatch: expected='$expected_clang_version' actual='$c'" >&2; exit 65; }
  s="$(xcrun --sdk iphoneos --show-sdk-version)"
  [ "$s" = "$expected_sdk_version" ] || { echo "iphoneos SDK mismatch: expected=$expected_sdk_version actual=$s" >&2; exit 65; }
}

mode="${1:---verify-only}"
case "$mode" in
  --manifest) member_manifest "$artifact"; exit 0 ;;
  --verify-only)
    echo "verify $artifact"
    [ -f "$artifact" ] || { echo "no artifact at $artifact" >&2; exit 66; }
    check_hash "artifact" "$artifact" "$expected_artifact_sha256"
    check_archive "$artifact" "$script_dir/libs/ios-arm64/$artifact_name.syms.txt"
    check_headers
    check_receipt
    if [ "$fails" -ne 0 ]; then echo "PW_LOD_IOS_VERIFY_FAILED ($fails check(s))" >&2; exit 66; fi
    echo "PW_LOD_IOS_VERIFIED sha256=$expected_artifact_sha256 engine=$engine_revision"
    exit 0 ;;
  --build) ;;
  --install)
    w="${2:?--install <work root>}"
    for f in "$artifact_name" "$artifact_name.receipt.json" "$artifact_name.syms.txt"; do
      [ -e "$script_dir/libs/ios-arm64/$f" ] && { echo "refusing to overwrite libs/ios-arm64/$f" >&2; exit 65; }
    done
    for f in pwlod_viewer.h pw_lod_bench.h; do
      if [ -e "$script_dir/include/$f" ] && ! cmp -s "$w/include/$f" "$script_dir/include/$f"; then
        echo "refusing to overwrite a different include/$f" >&2; exit 65
      fi
    done
    mkdir -p "$script_dir/libs/ios-arm64"
    cp "$w/$artifact_name" "$w/$artifact_name.receipt.json" "$w/$artifact_name.syms.txt" "$script_dir/libs/ios-arm64/"
    cp "$w/include/pwlod_viewer.h" "$w/include/pw_lod_bench.h" "$script_dir/include/"
    echo "installed into $script_dir/libs/ios-arm64/ — now set expected_* in this script from the receipt, then --verify-only"
    exit 0 ;;
  *) echo "usage: $0 [--verify-only|--manifest|--build <Aether3D repo>|--install <work root>]" >&2; exit 64 ;;
esac

# ─── --build ──────────────────────────────────────────────────────────────
repo="${2:?--build <Aether3D repo>}"
verify_toolchain
work="${PW_LOD_IOS_WORK_ROOT:-}"
case "$work" in
  /private/tmp/pw-lod-ios-*|/tmp/pw-lod-ios-*) ;;
  *) echo "PW_LOD_IOS_WORK_ROOT must be a new /private/tmp/pw-lod-ios-* path" >&2; exit 64 ;;
esac
[ -e "$work" ] && { echo "refusing to overwrite: $work" >&2; exit 65; }
[ "$(git -C "$repo" rev-parse "$engine_revision^{commit}")" = "$engine_revision" ] || {
  echo "engine revision $engine_revision not in $repo" >&2; exit 65; }
for f in $compile_flags; do [ "$f" = "$forbidden_flags" ] && { echo "forbidden flag $f" >&2; exit 65; }; done

mkdir -p "$work/src" "$work/obj" "$work/include"
# Sources straight from the pinned commit: clean by construction, no working tree involved.
git -C "$repo" archive --format=tar "$engine_revision" \
    aether_cpp/include/aether/pointcloud_lod aether_cpp/include/aether/pointcloud_lod_build \
    aether_cpp/include/aether/pointcloud_lod_render \
    aether_cpp/src/pointcloud_lod aether_cpp/src/pointcloud_lod_build aether_cpp/src/pointcloud_lod_render \
    aether_cpp/third_party/nlohmann | tar -x -C "$work/src"
A="$work/src/aether_cpp"
check_hash "engine pwlod_viewer.h == frozen ABI" "$A/include/aether/pointcloud_lod_render/pwlod_viewer.h" "$pwlod_viewer_h_sha256"
check_hash "engine pw_lod_bench.h" "$A/src/pointcloud_lod_render/m1_bench/pw_lod_bench.h" "$pw_lod_bench_h_sha256"
check_headers_dawn() {
  check_hash "include/dawn/webgpu.h" "$script_dir/include/dawn/webgpu.h" "$dawn_webgpu_h_sha256"
  check_hash "include/webgpu/webgpu.h" "$script_dir/include/webgpu/webgpu.h" "$webgpu_shell_h_sha256"
}
check_headers_dawn
[ "$fails" -eq 0 ] || { echo "input check failed" >&2; exit 65; }
cp "$A/include/aether/pointcloud_lod_render/pwlod_viewer.h" "$work/include/pwlod_viewer.h"
cp "$A/src/pointcloud_lod_render/m1_bench/pw_lod_bench.h" "$work/include/pw_lod_bench.h"

export SOURCE_DATE_EPOCH="$source_date_epoch"
export ZERO_AR_DATE=1
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
cxx="$(xcrun --sdk iphoneos --find clang++)"
objs=""
( cd "$A"
  for s in $sources; do
    o="$work/obj/$(basename "$s" .cpp).o"
    # shellcheck disable=SC2086
    "$cxx" -arch arm64 -isysroot "$sdk" -miphoneos-version-min="$minimum_ios" $compile_flags \
      "-DPWLOD_ENGINE_SHA8=\"$sha8\"" \
      -ffile-prefix-map="$A"=aether_cpp -ffile-prefix-map="$script_dir"=vendor/aether_lod \
      -Iinclude -Ithird_party -Isrc/pointcloud_lod_render/m1_bench -I"$script_dir/include" \
      -c "$s" -o "$o"
  done )
for s in $sources; do objs="$objs $work/obj/$(basename "$s" .cpp).o"; done
# shellcheck disable=SC2086
xcrun libtool -static -D -o "$work/$artifact_name" $objs
defined_syms "$work/$artifact_name" > "$work/$artifact_name.syms.txt"
mf="$work/member-manifest.txt"; member_manifest "$work/$artifact_name" > "$mf"

art_sha="$(hash_file "$work/$artifact_name")"
man_sha="$(hash_file "$mf")"
syms_sha="$(hash_file "$work/$artifact_name.syms.txt")"
und_n="$(nm -g -u "$work/$artifact_name" 2>/dev/null | awk '$1 ~ /^_wgpu/ {print $1} $2 ~ /^_wgpu/ {print $2}' | sort -u | wc -l | tr -d ' ')"
def_n="$(awk 'NF==3 && $3 ~ /^_wgpu/' "$work/$artifact_name.syms.txt" | wc -l | tr -d ' ')"

python3 - "$work/$artifact_name.receipt.json" <<PY
import json, sys
members = []
for line in open("$mf"):
    h, name = line.rstrip("\n").split("  ", 1)
    members.append({"member": name, "sha256": h})
r = {
  "schema": "pw.aether_lod.ios-arm64/1",
  "artifact": "$artifact_name",
  "artifact_sha256": "$art_sha",
  "archive_member_count": len(members),
  "archive_member_manifest_sha256": "$man_sha",
  "archive_member_manifest_format": "archive-order: sha256-two-spaces-member-newline",
  "archive_members": members,
  "syms_file": "$artifact_name.syms.txt",
  "syms_sha256": "$syms_sha",
  "syms_format": "nm -g --defined-only, archive-member headers normalised to 'member.o:'",
  "build_mode": "full_target_from_pinned_engine_commit",
  "engine_repository": "$engine_repository",
  "engine_revision": "$engine_revision",
  "engine_branch": "$engine_branch",
  "engine_branch_pushed": False,
  "source_tree_clean": True,
  "source_tree_clean_how": "git archive of the pinned commit (no working tree involved)",
  "declared_patches": [],
  "sources": "$sources".split(),
  "upstreams_inside": {
    "potree": "5636cd471d9eb464969e758be45c44d7613d3859 (BSD-2-Clause; selection, adaptive point size WGSL)",
    "PotreeConverter": "8bfad98d2a6b2111cdcb3840cb508b59408d0721 (BSD-2-Clause; on-device builder port)",
    "CesiumJS": "113c068e9af33dba22e5cc54f5a762b593ca3829 (Apache-2.0; controller, orthographic node size)",
    "three.js": "6101189ee28be14fe3a433a16712f9dd614972c6 (MIT; frustum)",
    "nlohmann/json": "v3.11.3 (MIT)",
    "pw_lod_bench": "pw_splat_ab_bench b792d57, pw_lod_bench.cpp sha256 50af752c1372aa881ff4dcc2b92e5fb0579daa36afc71567859938d21867b6c9 (byte-identical)"
  },
  "frozen_abi_header": {"file": "include/pwlod_viewer.h", "sha256": "$pwlod_viewer_h_sha256", "abi_version": int("$abi_version")},
  "webgpu_header": {"file": "include/dawn/webgpu.h", "sha256": "$dawn_webgpu_h_sha256",
                    "shell": "include/webgpu/webgpu.h", "shell_sha256": "$webgpu_shell_h_sha256",
                    "dawn_revision": "$dawn_revision", "license": "include/dawn/LICENSE",
                    "license_sha256": "$dawn_license_sha256"},
  "contains_dawn": False,
  "defined_wgpu_symbols": int("$def_n"),
  "undefined_wgpu_symbols": int("$und_n"),
  "exported_abi": "$expected_abi".split(),
  "pwlod_version": "$sha8 abi=$abi_version",
  "platform": "ios-arm64",
  "minimum_ios": "$minimum_ios",
  "compiler": "$expected_clang_version",
  "iphoneos_sdk": "$expected_sdk_version",
  "compile_flags": ["-arch arm64", "-miphoneos-version-min=$minimum_ios"] + "$compile_flags".split() + ["-DPWLOD_ENGINE_SHA8=\\"$sha8\\"", "-ffile-prefix-map=<work>/aether_cpp=aether_cpp"],
  "forbidden_compile_flags": ["$forbidden_flags"],
  "archiver": "xcrun libtool -static -D, ZERO_AR_DATE=1",
  "source_date_epoch": int("$source_date_epoch"),
  "build_script": "build_ios_lod.sh",
  "build_script_sha256": "$(hash_file "$0")",
  "link_notes_zh": "不含 Dawn:链接方必须再链一份 Dawn(台架 Release Dawn 普通归档;产品 ffi 自带的那份),三份同源 12ee391c、276 个 wgpu* 导出同名。入口靠 -force_load 或 -Wl,-u,_pwlod_viewer_create 等保住;不要用 -exported_symbol(台架 Podfile:155-161 记录会让 debug 包启动即崩)。"
}
json.dump(r, open(sys.argv[1], "w"), indent=2, ensure_ascii=False)
open(sys.argv[1], "a").write("\n")
PY

echo "PW_LOD_IOS_BUILT (staging only, not installed)"
echo "  path      = $work/$artifact_name"
echo "  artifact  = $art_sha"
echo "  manifest  = $man_sha  ($(wc -l < "$mf" | tr -d ' ') members)"
echo "  syms      = $syms_sha"
echo "  wgpu*     = defined $def_n, undefined $und_n"
