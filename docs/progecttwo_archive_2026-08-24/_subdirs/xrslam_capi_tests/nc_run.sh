#!/bin/zsh
SP=/private/tmp/claude-501/-Users-kaidongwang-Documents-progecttwo/00b9f4a7-61ae-40fd-a452-5f357f42dad3/scratchpad
source $SP/nc.sh
R=/Users/kaidongwang/Developer/xrslam
M=$R/xrslam-interface/src/XRSLAMManager.cpp

# --- NC1: 拆掉 landmark 的 isfinite 过滤 ---
python3 - <<'PY'
import io
p='/Users/kaidongwang/Developer/xrslam/xrslam-interface/src/XRSLAMManager.cpp'
s=io.open(p,encoding='utf-8').read()
a='if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z)) {'
assert a in s, "NC1 anchor"
s=s.replace(a,'if (false && (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z))) {',1)
io.open(p,'w',encoding='utf-8').write(s)
PY
run_case "NC1 landmark isfinite filter removed"

# --- NC2: 拆掉 triangulated 过滤 ---
python3 - <<'PY'
import io
p='/Users/kaidongwang/Developer/xrslam/xrslam-interface/src/XRSLAMManager.cpp'
s=io.open(p,encoding='utf-8').read()
a='''                if (!lm.triangulated) {
                    ++rej_untri;
                    if (require_triangulated) continue;
                }'''
assert a in s, "NC2 anchor"
s=s.replace(a,'''                if (!lm.triangulated) {
                    ++rej_untri;
                }''',1)
io.open(p,'w',encoding='utf-8').write(s)
PY
run_case "NC2 triangulated filter removed"

# --- NC3: 拆掉位姿退化闸 ---
python3 - <<'PY'
import io
p='/Users/kaidongwang/Developer/xrslam/xrslam-interface/src/XRSLAMManager.cpp'
s=io.open(p,encoding='utf-8').read()
a='    if (pose_is_degenerate(pose)) return XRSLAM_NO_NEW_DATA;'
assert a in s, "NC3 anchor"
s=s.replace(a,'    /* NC3 removed */',1)
io.open(p,'w',encoding='utf-8').write(s)
PY
run_case "NC3 pose degeneracy gate removed"

# --- NC4: 拆掉时间戳单调闸 ---
python3 - <<'PY'
import io
p='/Users/kaidongwang/Developer/xrslam/xrslam-interface/src/XRSLAMManager.cpp'
s=io.open(p,encoding='utf-8').read()
a='''int XRSLAMManager::gate_monotonic_locked(double t, double *last_t) {
    if (!std::isfinite(t)) {'''
assert a in s, "NC4 anchor"
s=s.replace(a,'''int XRSLAMManager::gate_monotonic_locked(double t, double *last_t) {
    if (t == t) { *last_t = t; return XRSLAM_OK; } /* NC4 */
    if (!std::isfinite(t)) {''',1)
io.open(p,'w',encoding='utf-8').write(s)
PY
run_case "NC4 timestamp monotonic/finite gate removed"

# --- NC5: 不读核内遥测(GetHealth 的视觉侧退回恒零) ---
python3 - <<'PY'
import io
p='/Users/kaidongwang/Developer/xrslam/xrslam-interface/src/XRSLAMManager.cpp'
s=io.open(p,encoding='utf-8').read()
a='        get_frame_health(fh);'
assert a in s, "NC5 anchor"
s=s.replace(a,'        /* NC5: get_frame_health(fh); */',1)
io.open(p,'w',encoding='utf-8').write(s)
PY
run_case "NC5 core telemetry not read"

# --- NC6: 域错配阈值放到天文数字 ---
python3 - <<'PY'
import io
p='/Users/kaidongwang/Developer/xrslam/xrslam-interface/src/XRSLAMManager.h'
s=io.open(p,encoding='utf-8').read()
a='    double  h_thr_delta_    = 1.0;'
assert a in s, "NC6 anchor"
s=s.replace(a,'    double  h_thr_delta_    = 1.0e30;',1)
io.open(p,'w',encoding='utf-8').write(s)
PY
run_case "NC6 domain-mismatch threshold defeated"
cp $SP/bak_XRSLAMManager.cpp /Users/kaidongwang/Developer/xrslam/xrslam-interface/src/XRSLAMManager.cpp
