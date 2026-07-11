// sfm_resume_wait_page.dart — 断点续跑(修2c)的等待页。
//
// 入口:草稿卡点击命中 DraftCardAction.offerResume,用户在确认框点了
// "继续重建"。本页只负责可视化 resumeSingleCapture() 的进度与结果:
//   • 恢复本身跑在 sfm_resume.dart 的模块级 future 上,**不归本页 State
//     所有** —— 用户左上角返回后重建继续跑,再点同一张卡直接挂回同一
//     future(me_page 侧用 isResumeInFlight 判断,跳过二次确认框)。
//     这与拍摄等待页"返回草稿不销毁 worker"同一契约精神。
//   • 成功(sfm_sparse.ply 已持久化)→ 显示"查看点云",替换路由到
//     SparseCloudViewerPage;失败 → 说明素材已保留,可稍后重试。
//
// 有意不复用 SfmPreviewOverlay:它的 phase/snapshot 契约绑定拍摄页的
// colorize/persist 流,而恢复腿在 sfm_resume.dart 里是无头完成的,
// 本页只需要 spinner + 计时 + 终态两个按钮。

import 'dart:async';

import 'package:flutter/material.dart';

import '../../capture/sfm_resume.dart';
import 'sparse_cloud_viewer_page.dart';

class SfmResumeWaitPage extends StatefulWidget {
  const SfmResumeWaitPage({
    super.key,
    required this.captureDir,
    required this.title,
  });

  /// 已通过 resolveRecoverableCaptureDir 解析的、当前容器内的 capture 目录。
  final String captureDir;

  /// 草稿名(成功后点云查看器沿用)。
  final String title;

  @override
  State<SfmResumeWaitPage> createState() => _SfmResumeWaitPageState();
}

class _SfmResumeWaitPageState extends State<SfmResumeWaitPage> {
  bool _done = false;
  bool _ok = false;
  Timer? _ticker;
  final DateTime _enteredAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    // 幂等:已在跑就挂到同一 future(绝不起第二个 worker)。
    resumeSingleCapture(widget.captureDir).then((ok) {
      if (!mounted) return;
      setState(() {
        _done = true;
        _ok = ok;
      });
      _ticker?.cancel();
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && !_done) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _elapsedText() {
    final secs = DateTime.now().difference(_enteredAt).inSeconds;
    return secs < 60 ? '$secs 秒' : '${secs ~/ 60} 分 ${secs % 60} 秒';
  }

  void _openCloud() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => SparseCloudViewerPage(
          plyPath: '${widget.captureDir}/sfm_sparse.ply',
          title: widget.title.isEmpty ? '稀疏点云' : widget.title,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      body: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 0, 0),
                child: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: '返回',
                  icon: const Icon(Icons.arrow_back_ios_new_rounded),
                  color: Colors.white,
                  iconSize: 22,
                ),
              ),
            ),
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!_done) ...[
                    const SizedBox(
                      width: 30,
                      height: 30,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      '正在继续重建…',
                      style: TextStyle(color: Colors.white, fontSize: 15),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '从已保存的重建数据恢复,无需重拍 · 已 ${_elapsedText()}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '可以返回,重建会在后台继续;再次点击这张草稿卡可回到本页',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                  ] else if (_ok) ...[
                    const Icon(
                      Icons.check_circle_rounded,
                      color: Color(0xFF6EE7A0),
                      size: 40,
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      '重建完成',
                      style: TextStyle(color: Colors.white, fontSize: 15),
                    ),
                    const SizedBox(height: 20),
                    GestureDetector(
                      onTap: _openCloud,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 44,
                          vertical: 13,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(26),
                        ),
                        child: const Text(
                          '查看点云',
                          style: TextStyle(
                            color: Colors.black,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ] else ...[
                    const Icon(
                      Icons.cloud_off_rounded,
                      color: Colors.white38,
                      size: 40,
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      '这次未能完成重建,素材已保留',
                      style: TextStyle(color: Colors.white, fontSize: 15),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '可稍后在草稿里再次尝试(设备冷却后成功率更高)',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
