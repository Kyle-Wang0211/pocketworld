#!/bin/bash
# run.sh <tag> <scene 13f5|6d18|7353|path> <bin> [runner args...]
# [xrchain 2026-09-25] 喂法逐项照抄 preint/tools/run.sh(手机同款:box/3、30 Hz 闸 0.8/R、首个 IMU 之前的相机帧丢弃、
# 逐帧 K、曝光中点 t = PTS + exposure/2 + c,c = yaml cam0.time_offset)。节奏由调用方给(--pace)。
# 与其它 agent 共用 scratchpad/.xrslam_run.lock(mkdir 锁),回放不并发。配置只读取用 preint/cfg。
SP=/private/tmp/claude-501/-Users-kaidongwang-Documents-progecttwo/2359d42b-b338-4098-99ad-6a4c217067ad/scratchpad
W=$SP/xrchain; R=$HOME/Developer/viobench-recordings
TAG=$1; SC=$2; BIN=$3; shift 3
SL=$SP/preint/cfg/slam_config.yaml; DEV=$SP/preint/cfg/dev_13f5.yaml
case $SC in
  13f5) RUN=$R/run-13f53d2f-5935-4b1a-a499-4dc8367ea935; DEV=$SP/preint/cfg/dev_13f5.yaml;;
  6d18) RUN=$R/run-6d187dff-403a-4882-b692-7bdc6c3cfa2a; DEV=$SP/preint/cfg/dev_6d18.yaml;;
  7353) RUN=$R/run-73538ad6-8418-4eaf-8b75-a63c9d32af46; DEV=$SP/preint/cfg/dev_7353.yaml;;
  /*) RUN=$SC;;
  *) echo bad scene; exit 2;;
esac
kb=$(df -k ~ | tail -1 | awk '{print $4}'); [ "$kb" -ge $((3*1024*1024)) ] || { echo "STOP: 盘 < 3 GB"; exit 90; }
L=$SP/.xrslam_run.lock
until mkdir $L 2>/dev/null; do sleep 0.3; done
echo "xrchain $$ $(date +%T) $TAG" > $L/owner
trap 'rm -f $L/owner; rmdir $L 2>/dev/null' EXIT
echo "$TAG run=$RUN bin=$BIN dev=$(basename $DEV) $* loadavg1=$(sysctl -n vm.loadavg | awk '{print $2}') start=$(date +%T)" > $W/runs/$TAG.cmd
$W/v/$BIN/pwvi_runner $SL $DEV pwvi://$RUN $W/runs/$TAG.body.tum --downscale 3 --rate-hz 30 --rate-frac 0.8 \
   --drop-before-imu --intrinsics-jsonl --exposure-half --hex-out $W/runs/$TAG.hex --frame-map-out $W/runs/$TAG.map "$@" \
   > $W/runs/$TAG.log 2>&1
RC=$?
echo "end=$(date +%T) rc=$RC" >> $W/runs/$TAG.cmd
echo "rc=$RC $TAG"; grep -E "^\[pwvi\]|=== " $W/runs/$TAG.log
