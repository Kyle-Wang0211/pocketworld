// PwBenchReplayEngineProbe.h —— 台架回放的两个**只读**引擎读数。
//
// 只进台架(arloopbench)。生产 Runner.xcodeproj 不编它,生产桥接头不 import 它。
// 不改引擎、不改传输层:两样都是对已链进来的引擎做只读查询。
//
// ① PWBenchReplayReadBodyPose —— `XRSLAMGetResult(XRSLAM_RESULT_BODY_POSE)` 一次。
//    为什么要它:传输层交出的是 CAMERA_POSE(PwXrslamTransportCore.cpp 读的那个,
//    产品用它);Mac 宿主回放 pw_euroc_runner 写的是 BODY_POSE
//    (xrslam fork pw_tools/regression/euroc_runner.cpp:205-206)。台架两份都写,
//    Mac 上才能拿同一口径逐行比。GetResult* 在引擎里是 const 成员
//    (fork XRSLAMManager.cpp:318-346),不改状态。调用点在 PwXrslamLive 的 worker 上、
//    本帧 push→run→result 之后、下一次推送之前 ⇒ 与 runner 在 RunOneFrame 之后
//    立刻读 BODY_POSE 是同一个时刻。
// ② PWBenchReplayTelemetryTake —— 引擎自带的只读遥测计数器。符号表与单位逐字抄
//    xrslam fork feat/solver-time-budget @b0937ef `pw_tools/regression/euroc_runner.cpp`
//    的 Telemetry::bind / take(pw_solver_* 来自该分支 estimation/solver.cpp:14-31;
//    pw_bk_* 来自 core/frontend_worker.cpp:23-29)。
//    runner 用 dlsym 找;iOS 归档是 -fvisibility=hidden 编的(receipt cmake ENABLE_VISIBILITY=0),
//    这些符号在最终 App 里不导出,dlsym 找不到 ⇒ 这里改用**弱定义 + 哨兵值**:
//    本文件给每个符号一个 weak 定义(计数 = UINT64_MAX、毫秒 = −1),链进来的引擎归档里
//    若有同名的强定义,链接器按规则选强定义,读到的就是引擎自己的计数;没有(generic /
//    b9b14814 臂)就读到哨兵 ⇒ 报 −1 / NAN,与 runner 对旧库的「找不到就留空」同义。
//    引擎源码一行不动;静态链接对 hidden 符号的同镜像引用本来就合法。
//    判读:pfk 臂(04c0e83)里有 pw_bk_*(`nm -m` 核过是 private external 定义),
//    没有 pw_solver_*;时间预算臂(b0937ef)两组都有。

#ifndef PW_BENCH_REPLAY_ENGINE_PROBE_H_
#define PW_BENCH_REPLAY_ENGINE_PROBE_H_

#include <stdint.h>

#include "../../vendor/xrslam/transport/PwXrslamTransportCore.h"

#ifdef __cplusplus
extern "C" {
#endif

void PWBenchReplayReadBodyPose(PWXrslamRawPose *out);

typedef struct PWBenchReplayTelemetry {
  // 毫秒;符号不在 ⇒ NAN
  double scoped_ms;
  double unscoped_ms;
  double bk_work_ms;
  double bk_track_ms;
  // 计数;符号不在 ⇒ -1
  int64_t scoped_calls;
  int64_t scoped_iters;
  int64_t stop_budget;
  int64_t stop_time;
  int64_t stop_iter;
  int64_t stop_conv;
  int64_t bk_track_n;
} PWBenchReplayTelemetry;

void PWBenchReplayTelemetryTake(PWBenchReplayTelemetry *out);

// 链进来的引擎里有几个遥测符号(0..11;哨兵 = 不在)。
int32_t PWBenchReplayTelemetrySymbolCount(void);

// ③ [bench 2026-09-25] 后端(滑动窗口 BA)已优化帧位姿 —— xrslam fork feat/backend-pose-output@8ebac9a
//    新增的只读出口 XRSLAMDrainBackendPoses / XRSLAMGetBackendWindowPoses(声明与布局见
//    vendor/xrslam/include/XRSLAMBackendPose.h,与引擎提交里那份逐字节相同)。
//    同 ② 的做法:.c 里给两个引擎函数各一个**弱定义**,返回 -1;链进来的引擎归档有强定义就用引擎的,
//    没有(generic / gpufenothread / pfk / official_rules_89042cd5 臂)就如实得到 -1 =「这个引擎没有后端出口」。
//    只读:取走的是引擎已经算好、放在出口里的记录,不碰任何参与计算的状态。
#include "../../vendor/xrslam/include/XRSLAMBackendPose.h"

// 取走 First / Final 事件;返回条数,-1 = 链进来的引擎没有这个出口。*dropped 同引擎语义。
int32_t PWBenchReplayDrainBackendPoses(XRSLAMBackendPose *out, int32_t capacity,
                                       uint64_t *dropped);
// 最近一次后端 track() 结束时的整窗快照;返回快照总条数,-1 = 没有这个出口。
int32_t PWBenchReplayBackendWindowPoses(XRSLAMBackendPose *out, int32_t capacity);
// 引擎内部 worker 队列里还没处理的帧数(XRSLAMGetPendingWorkerFrames);-1 = 符号不在。
int32_t PWBenchReplayEnginePendingFrames(void);

#ifdef __cplusplus
}
#endif

#endif  // PW_BENCH_REPLAY_ENGINE_PROBE_H_
