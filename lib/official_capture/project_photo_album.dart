import 'dart:io';

import 'package:flutter/foundation.dart';

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
/// committed only after the canonical 4032×3024 JPEG exists and its same-frame
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
    if (jpegPath.isEmpty ||
        !captureTimestamp.isFinite ||
        imageWidth != 4032 ||
        imageHeight != 3024 ||
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
