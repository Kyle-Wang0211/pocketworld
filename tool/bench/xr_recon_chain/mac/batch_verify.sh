#!/bin/bash
# batch_verify.sh <scene...> —— [xrchain] 每场:自检回放(--backend-out + --propagate-selftest)→ 参照 xr_propagate2 → 链路回放(--chain)
SP=/private/tmp/claude-501/-Users-kaidongwang-Documents-progecttwo/2359d42b-b338-4098-99ad-6a4c217067ad/scratchpad
cd $SP/xrchain
runof() { case $1 in 13f5) echo run-13f53d2f-5935-4b1a-a499-4dc8367ea935;; 6d18) echo run-6d187dff-403a-4882-b692-7bdc6c3cfa2a;; 7353) echo run-73538ad6-8418-4eaf-8b75-a63c9d32af46;; esac; }
for sc in "$@"; do
  nice -n 5 ./tools/run.sh st_$sc $sc xrc_off --td-extra-ms -5 --backend-out runs/st_$sc.backend.csv --keyed-out runs/st_$sc.keyed.csv \
     --propagate-selftest photos/$sc.txt runs/st_$sc.prop runs/st_$sc.jobs
  v/xrprop_ref/xr_propagate2 $SP/preint/cfg/slam_config.yaml $SP/preint/cfg/dev_$sc.yaml ~/Developer/viobench-recordings/$(runof $sc)/imu.csv \
     runs/st_$sc.jobs runs/st_$sc.ref 2>&1 | tail -1
  nice -n 5 ./tools/run.sh ch_$sc $sc xrc_off --td-extra-ms -5 --chain photos/$sc.txt runs/ch_$sc.tsv
done
