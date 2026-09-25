tool/bench/xr_recon_chain/mac —— 台架 XRSLAM → SfM 重建链的 Mac 端工具(2026-09-25,xr-recon-chain)。
脚本里的路径是当时的 scratch 工作目录(照 preint / bkpose 各轮的惯例原样留档,换机器要改 W/SP)。

pwvi_runner.cpp        Mac 回放器(preint/tools/pwvi_runner.cpp 的新版):
                       · 新 IMU 录制格式 imu_events.csv(两路各自时间戳)与旧 imu.csv 都能读(旧格式逐位不变);
                       · --propagate-selftest:回放结束后对每张照片取「≤ t_photo 的最近后端帧」的 FINAL(否则收尾窗口)
                         调 XRSLAMPropagateBackendState,输出与 offline_sfm/tools/xr_propagate2.cc 同列布局,另出作业文件;
                       · --chain:用与手机同一份源码的链路核心(vendor/xrslam/chain/PwXrReconChainCore.cpp)按数据时间回放。
build_mac.sh           引擎 + 回放器 Mac 构建(配方照抄 preint/tools/build_mac.sh;RUNNER_DEFS 带 -DPW_XRCHAIN 编进核心)。
build_xr_propagate2_ref.sh  参照外推工具(xr_propagate2.cc 逐字节拷贝,#include 4e8dda2 detail.cpp)。
run.sh / batch_verify.sh / summarize_chain.py   手机同款喂法 + 台架 Δ −5 ms 回放、自检、参照比对、链路回放与汇总。
build_ios.sh / build_ios_pair.sh   iOS 归档(同 preint 配方)+ 对父提交 4e8dda2 的逐成员归因对照。
make_photos.py + photos/   Mac 链路回放用的模拟照片时刻。
