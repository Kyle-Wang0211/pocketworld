# tasks — dense-lossless-speedup-v1(app 侧)
- [x] 0.1 vendor/pw_dense/include/pwdense_c.h 同步为 v3
- [x] 3.1 lib/dense/pw_dense_ffi.dart:PwDenseFrame 可选 nv12 字段;`pwdense_run3` 可选绑定,缺失时回退 run2(NV12 帧则回退 JPEG 物化)
- [x] 3.2 lib/dense/native_dense_stage_launcher.dart + lib/official_capture/photo_archive_resolver.dart:PWVA 帧解成 .nv12 临时文件(跨 isolate 并行),`_gather` 计时进 DeviceLog
- [x] 3.3 test/dense 覆盖:v3 结构体布局、回退、NV12 解析、gather 日志
- [ ] 4.x 导出清单 + build_xcframeworks.sh(主线做)
