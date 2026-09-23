# dense-lossless-speedup-v1 — 机上稠密管线无损提速(A 组)+ 归档作品去 JPEG 往返(方案甲)

日期 2026-09-16。承接 dense-pointcloud-ondevice-v1(Stage 1–3)。用户令:"②按 A 组做;③选甲,先提速,因为后面照片是要删除的,
不用复现"。硬约束:所有提升 iOS / Android / 鸿蒙同源,不为任一系统单独优化;A 组改动对新鲜作品(JPEG 路径)**逐字节不变**
(pack `depth/conf*.f32` + `official_dense.ply`)。调研与证据:pocketworld_research_benchmarks/experiments/dense_ondevice_2026-09-15/
evidence/lossless-speedup-survey-2026-09-16.md。

## 时间账(生产 09-15 首跑,21 张,58.2 s)
推理 51.0 s(88%)/ 融合 3.4 s(推理循环内同线程串行,GPU 空转)/ 解码+PIL 缩放 1.5 s(单线程)/ 建会话 1.2 s(与解码串行)。

## A 组(确认无损,纯调度,三端同源)
- A1 融合搬到工作线程,与下一视图 GPU 推理重叠;`Run` 仍只在调用线程串行;chunk/progress 回调仍只在调用线程发(Dart 的
  `NativeCallable.isolateLocal` 只能在调用 isolate 的线程上被调);PLY 仍按帧序拼装(FuseScheduler + spill 不变)。
- A2 图像解码 + PIL 缩放跨图并行(每图独立解码器;libjpeg-turbo doc/libjpeg.txt:244-247 明许多对象并发)。
- A3 解码与 ORT 建会话重叠;A4 下一视图 imgbuf(f16→f32×3)双缓冲预备。
- A5–A7 EP 旋钮(validationMode=disabled / maxNumPendingDispatches / defaultBufferCacheMode):只在台架量,逐字节闸过了再进生产。

## 方案甲(归档作品)
PWVA 已接管的作品今天走「HEVC 解码 → ImageIO 重编 JPEG q0.95 → 再解码」(Dart `photo_archive_resolver.dart`),逐张串行、
无计时、两代有损、且 ImageIO 是苹果专属。改为:Dart 把解码出的 NV12(full range)写成临时 .nv12 文件,C ABI v3
`pwdense_run3` 收 `pwdense_frame_v3_t{nv12_path,nv12_width,nv12_height,nv12_matrix}`,C++ 用 libyuv(BSD-3)转 RGB 后走
**同一条** PIL 缩放 → L → f16 链。JPEG 路径(新鲜作品)不动。

## 闸
1. 主机:`test_images` 串行 vs 并行 images.f16/rgb 逐字节;`test_progressive` 不变;端到端 `dense_run` 旧二进制 vs 新二进制
   同输入 pack + PLY sha(主机 ORT 1.29 WebGPU,.deps.nosync/ort_build);NV12 路径阳性对照(同一张图 JPEG 路径 vs
   RGB→NV12→路径,±2 以内)+ 阴性对照(错矩阵必须明显不同)。
2. 真机台架(com.kyle.casdiffdensebench,单场 ≤300 s,轮转臂序):旧/新 pack + PLY sha 逐字节;墙钟分账。
3. 生产:只换 App + PWDense,其余与机上包逐字节同;装机待用户令。
