# tasks — live-wait-page-v1

- [x] 1.1 调研(四路 ETA + 一路相机换算),出处表进 design.md
- [x] 2.1 lib/eta:Ninja 逐行移植 + 先验日志 + 一次性提交标签 + 尺子(12 单测)
- [x] 2.2 worker:排空期继续逐帧 preview;phase-1 落地发 `finalize_local_live`(源码锚点测试 8)
- [x] 2.3 覆盖层:去顶部 chip;底部倒计时胶囊;有云时不画转圈(6 单测)
- [x] 2.4 相机:CloudCamera camDistOverride/orthoMix;SparseCloudView 透视起始态 + 首手势过渡;capture_pose_camera.dart(5 单测 + 2 widget)
- [x] 2.5 页面接线:白云 + 起始态 + 倒计时生命周期(源码锚点测试 6)
- [ ] 3.1 出包 163(DART_ONLY 覆盖 162)+ 五道闸;等用户"装"
- [ ] 3.2 真机第一场:肉眼判"关灯了点云在原地" + 倒计时命中(eta_ruler)
- [ ] 4.x 后续:再进入走同一页;稠密接同一页并逐帧出点;全局 BA Ceres 迭代计数(动核)
