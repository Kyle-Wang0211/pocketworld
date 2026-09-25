import 'dart:io';

import 'package:flutter/foundation.dart';

import '../vio/capture/photo_size_rule.dart';
import 'photo_card_state.dart';

class OfficialProjectPhoto {
  const OfficialProjectPhoto({
    required this.jpegPath,
    required this.captureTimestamp,
    this.analysisState = PhotoCardSfmState.pending,
  });

  final String jpegPath;
  final double captureTimestamp;
  final PhotoCardSfmState analysisState;

  OfficialProjectPhoto withAnalysisState(PhotoCardSfmState value) =>
      OfficialProjectPhoto(
        jpegPath: jpegPath,
        captureTimestamp: captureTimestamp,
        analysisState: value,
      );
}

/// The one user-visible photo ledger for an official capture.
///
/// Ring-buffer coverage, SfM queue depth, and upload curation are internal
/// implementation details. They must never change this count. An entry can be
/// committed only after the verified JPEG (any 4:3 raw grid with long side >= 1920,
/// [photoSizeVerdict]) exists and its same-frame
/// AR data has already passed [OfficialHighResReconstructionInput.validate].
class OfficialProjectPhotoAlbum extends ChangeNotifier {
  final List<OfficialProjectPhoto> _photos = <OfficialProjectPhoto>[];
  final Set<String> _paths = <String>{};

  int get count => _photos.length;

  String? get latestPath => _photos.isEmpty ? null : _photos.last.jpegPath;

  List<OfficialProjectPhoto> get photos =>
      List<OfficialProjectPhoto>.unmodifiable(_photos);

  List<String> get paths =>
      List<String>.unmodifiable(_photos.map((photo) => photo.jpegPath));

  int get analyzedCount => _photos
      .where((photo) => photo.analysisState != PhotoCardSfmState.pending)
      .length;

  int get disconnectedCount => _photos
      .where((photo) => photo.analysisState == PhotoCardSfmState.disconnected)
      .length;

  double get disconnectedRatio =>
      analyzedCount == 0 ? 0 : disconnectedCount / analyzedCount;

  /// Mirrors RealityScan's capture-time warning: do not warn until one full
  /// 20-photo analysis cohort exists, then warn only when more than 20% of the
  /// analyzed photos are disconnected. Pending photos stay in the project but
  /// do not dilute a result that the solver has not produced yet.
  bool get shouldWarnDisconnected =>
      analyzedCount >= 20 && disconnectedRatio > 0.20;

  bool commitVerified({
    required String jpegPath,
    required double captureTimestamp,
    required int imageWidth,
    required int imageHeight,
  }) {
    // [ENTRY-ANY-4X3 2026-09-25] 原来写死 4032x3024;改为与重建入口同一份判据。
    if (jpegPath.isEmpty ||
        !captureTimestamp.isFinite ||
        !photoSizeVerdict(imageWidth, imageHeight).accepted ||
        _paths.contains(jpegPath)) {
      return false;
    }
    final file = File(jpegPath);
    if (!file.existsSync() || file.lengthSync() <= 0) return false;

    _paths.add(jpegPath);
    _photos.add(
      OfficialProjectPhoto(
        jpegPath: jpegPath,
        captureTimestamp: captureTimestamp,
      ),
    );
    notifyListeners();
    return true;
  }

  /// [2026-09-08 补拍] 装入**上一次拍摄**已落盘的照片。返回实际装入的张数。
  ///
  /// 为什么必须有:补拍复用同一个 capture 目录,而这个计数器是"**这个项目**有
  /// 多少张",不是"这次会话拍了多少张"。它同时喂着三处 —— 相册上的 N/300、
  /// 「至少 20 张」的完成闸、300 张上限。只算本次会话的话,一个已有 10 张的
  /// 项目在补拍时会显示 20/300,用户以为还得再拍满 20 张(实测如此)。
  ///
  /// 与 [commitVerified] 的区别:这些照片是**上一次**经同一条验证落盘的,
  /// 尺寸校验([photoSizeVerdict])在当时就做过了,这里不再重复(也无法重复 —— 读尺寸
  /// 要解码)。这里只确认文件还在、非空、不重复。
  ///
  /// 分析态一律 [PhotoCardSfmState.pending]:本次会话的 SfM 确实还没处理过
  /// 它们,这是字面事实。pending 不进 [analyzedCount],所以既不会稀释
  /// [disconnectedRatio],也不会凭空点亮 [shouldWarnDisconnected]。
  int adoptExisting(Iterable<String> jpegPaths) {
    var adopted = 0;
    final sorted = jpegPaths.toList()..sort();
    for (final jpegPath in sorted) {
      if (jpegPath.isEmpty || _paths.contains(jpegPath)) continue;
      final file = File(jpegPath);
      if (!file.existsSync() || file.lengthSync() <= 0) continue;
      _paths.add(jpegPath);
      _photos.add(
        OfficialProjectPhoto(
          jpegPath: jpegPath,
          // 上一次的快门时刻已不可得;用文件修改时间,单调且只用于排序。
          captureTimestamp:
              file.statSync().modified.millisecondsSinceEpoch / 1000.0,
        ),
      );
      adopted++;
    }
    if (adopted > 0) notifyListeners();
    return adopted;
  }

  bool updateAnalysisState(String jpegPath, PhotoCardSfmState analysisState) {
    final index = _photos.indexWhere((photo) => photo.jpegPath == jpegPath);
    if (index < 0 || _photos[index].analysisState == analysisState) {
      return false;
    }
    _photos[index] = _photos[index].withAnalysisState(analysisState);
    notifyListeners();
    return true;
  }

  bool remove(String jpegPath) {
    if (!_paths.remove(jpegPath)) return false;
    _photos.removeWhere((photo) => photo.jpegPath == jpegPath);
    notifyListeners();
    return true;
  }

  void clear() {
    if (_photos.isEmpty) return;
    _photos.clear();
    _paths.clear();
    notifyListeners();
  }
}
