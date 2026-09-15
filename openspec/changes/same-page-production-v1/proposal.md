# same-page-production-v1 — 一个页面贯穿拍摄 → 稀疏 → 稠密(→ mesh)

日期 2026-09-15 深夜。承接 live-wait-page-v1。用户令:"下一步:从个人页再进入走同一页;稠密接同一页并逐帧出点;
全局 BA 的 Ceres 迭代计数(动核)。开始。可以安排多个子 agent(opus5)辅助,千万不要耦合,仔细检查。"

## 三项
1. **再进入走同一页**:画廊点项目 → `OfficialARCapturePage(reviewCaptureDir:)`(不开相机、不重建,装盘上的稀疏云进
   refined 态;编辑 / 下一步 / 保存草稿同拍完页;返回箭头直接 pop)。老记录没有目录才退回只读 PLY 查看器。
   顺手修:只重建/查看模式没有 CaptureSession,`_session?.captureDir` 在那两条路上是 null ⇒ 落盘/选区/稠密都走
   `_pageCaptureDir`(以前只重建路径的 PLY 落盘会被静默跳过)。
2. **稠密接同一页并逐帧出点**:C ABI v2 `pwdense_run2(..., chunk)` 每个参考帧融合完立刻回调(依赖序:参考帧 + 其
   nsrc 源视图推理完即融合),最终 PLY 与 v1 逐字节相同(按帧序写);Dart 端 `DenseLiveCloud` 在 100 万显示预算
   (Potree 默认)下按帧定步长抽样累积;页面在"下一步"后留在原页:稀疏云被逐帧长出的稠密云替换,底部胶囊显示稠密倒计时
   (`DenseWaitEta`,页面外的全局观察器,重进页面不丢已提交的标签),结束后底部"完成"。
3. **全局 BA 迭代计数(动核)**:先查可行性 —— 核里的 Ceres 选项、状态旗 C ABI、PWOfficialSfm 框架能否从已提交源码
   逐字节复现机上二进制(另一条线有 ~190 个未提交文件,09-11 曾因此静默丢掉预热刀)。查完再决定动不动。

## 防耦合
子代理各自只碰各自的文件:C++ 只碰 `aether_cpp/src/dense/`;Dart 接收端只碰 `lib/dense/`;页面/覆盖层/路由由主线改;
核的调研只读。每项都带测试;全仓 `flutter test` 必须与 163 时相同(仅 xrslam Android .so 那条长期红)。
