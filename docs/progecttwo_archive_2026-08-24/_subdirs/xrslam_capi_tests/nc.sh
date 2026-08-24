#!/bin/zsh
# [pw] 负向对照驱动:打补丁 -> 重编 -> 跑判据 -> 无条件还原。
set -u
R=/Users/kaidongwang/Developer/xrslam
SP=/private/tmp/claude-501/-Users-kaidongwang-Documents-progecttwo/00b9f4a7-61ae-40fd-a452-5f357f42dad3/scratchpad
M=$R/xrslam-interface/src/XRSLAMManager.cpp
H=$R/xrslam-interface/include/XRSLAM.h
MH=$R/xrslam-interface/src/XRSLAMManager.h

restore() { cp "$SP/bak_XRSLAMManager.cpp" "$M"; cp "$SP/bak_XRSLAM.h" "$H"; cp "$SP/bak_XRSLAMManager.h" "$MH"; }
cp "$M" "$SP/bak_XRSLAMManager.cpp"; cp "$H" "$SP/bak_XRSLAM.h"; cp "$MH" "$SP/bak_XRSLAMManager.h"
trap restore EXIT INT TERM

run_case() {
  local name="$1"; shift
  echo "==================== NC: $name ===================="
  # 补丁已由调用方施加
  ( cd "$R" && ninja -C build-v1 -j 2 xrslam ) >"$SP/nc_build.log" 2>&1
  local brc=$?
  if [ $brc -ne 0 ]; then
    echo "RESULT: BUILD RED (expected for compile-time criteria)"
    grep -E "error:" "$SP/nc_build.log" | head -4
    restore; return 0
  fi
  ( cd "$R" && sh "$SP/compile_lm.sh" ) >/dev/null 2>&1
  ( cd "$R/build-v1" && sh "$SP/link_lm.sh" ) >/dev/null 2>&1
  ( cd "$R" && "$SP/pw_api_test_v1" configs/iphone_slam.yaml configs/iphonex.yaml ) >"$SP/nc_api.log" 2>&1
  local arc=$?
  ( cd "$R" && "$SP/pw_lm_test" configs/iphone_slam.yaml configs/iphonex.yaml ) >"$SP/nc_lm.log" 2>&1
  local lrc=$?
  echo "api_test rc=$arc  $(grep -o '==== pass=[0-9]* fail=[0-9]* ====' "$SP/nc_api.log")"
  echo "lm_test  rc=$lrc  $(grep -o '==== lm pass=[0-9]* fail=[0-9]* ====' "$SP/nc_lm.log")"
  grep "FAIL" "$SP/nc_api.log" "$SP/nc_lm.log" | head -8
  if [ $arc -ne 0 ] || [ $lrc -ne 0 ]; then echo "RESULT: RED (good)"; else echo "RESULT: STILL GREEN (BAD -- criterion is blind)"; fi
  restore
}
