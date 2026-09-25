#!/bin/bash
# build_ios_pair.sh —— [xrchain] 同一构建目录先编父提交 4e8dda2(对照),再编 feat/xr-recon-chain(本臂),逐成员比。
set -euo pipefail
SP=/private/tmp/claude-501/-Users-kaidongwang-Documents-progecttwo/2359d42b-b338-4098-99ad-6a4c217067ad/scratchpad
W=$SP/xrchain; X=$W/xrslam-wt; O=$W/ios_out; mkdir -p $O
kb=$(df -k ~ | tail -1 | awk '{print $4}'); [ "$kb" -ge $((3*1024*1024)) ] || { echo "STOP 盘 < 3 GB"; exit 90; }
git -C $X checkout -q --detach 4e8dda2
JOBS=${JOBS:-4} nice -n 10 $W/tools/build_ios.sh ON $O/control_4e8dda2.a
git -C $X checkout -q feat/xr-recon-chain
[ "$(git -C $X rev-parse --short HEAD)" = cd3469c ] || { echo "HEAD 不对"; exit 1; }
JOBS=${JOBS:-4} nice -n 10 $W/tools/build_ios.sh ON $O/xrchain.a
S=$(shasum -a 256 $O/xrchain.a | cut -c1-8); cp $O/xrchain.a $O/libxrslam_official_rules_xrchain_$S.a
cp $O/xrchain.a.syms.txt $O/libxrslam_official_rules_xrchain_$S.a.syms.txt
echo "ARTIFACT libxrslam_official_rules_xrchain_$S.a"
mkdir -p $O/m_ctrl $O/m_new; (cd $O/m_ctrl && rm -f *.o && xcrun ar -x ../control_4e8dda2.a); (cd $O/m_new && rm -f *.o && xcrun ar -x ../xrchain.a)
for f in $(ls $O/m_new | sort); do cmp -s $O/m_ctrl/$f $O/m_new/$f || echo "DIFF $f"; done
echo "members ctrl=$(ls $O/m_ctrl | wc -l) new=$(ls $O/m_new | wc -l)"
grep -E " T _XRSLAM(PropagateBackendState|DrainBackendStates|GetBackendWindowStates|DrainBackendPoses)$" $O/xrchain.a.syms.txt
