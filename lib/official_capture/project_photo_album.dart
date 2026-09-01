import 'dart:async';

import 'package:flutter/foundation.dart';

import 'accepted_photo_record_store.dart';
import 'accepted_photo_transaction.dart';
import 'photo_card_state.dart';

class OfficialProjectPhoto {
  const OfficialProjectPhoto({
    required this.transactionId,
    required this.jpegPath,
    required this.captureTimestamp,
    this.analysisState = PhotoCardSfmState.pending,
  });

  final String transactionId;
  final String jpegPath;
  final double captureTimestamp;
  final PhotoCardSfmState analysisState;

  OfficialProjectPhoto withAnalysisState(PhotoCardSfmState value) =>
      OfficialProjectPhoto(
        transactionId: transactionId,
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
  OfficialProjectPhotoAlbum() {
    _registrySubscription = AcceptedPhotoRecordRegistry.changes.listen((_) {
      _dropOrphanedAnalysisState();
      notifyListeners();
    });
  }

  late final StreamSubscription<void> _registrySubscription;
  final Map<String, PhotoCardSfmState> _analysisByTransaction =
      <String, PhotoCardSfmState>{};

  int get count => AcceptedPhotoRecordRegistry.snapshot.length;

  String? get latestPath {
    final records = AcceptedPhotoRecordRegistry.snapshot;
    return records.isEmpty ? null : records.last.jpegPath;
  }

  List<OfficialProjectPhoto> get photos =>
      List<OfficialProjectPhoto>.unmodifiable(
        AcceptedPhotoRecordRegistry.snapshot.map(_projectPhoto),
      );

  List<String> get paths => List<String>.unmodifiable(
    AcceptedPhotoRecordRegistry.snapshot.map((record) => record.jpegPath),
  );

  int get analyzedCount => photos
      .where((photo) => photo.analysisState != PhotoCardSfmState.pending)
      .length;

  int get disconnectedCount => photos
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

  /// Compatibility receipt for callers that have not moved to
  /// [CaptureSession.canonicalPhotoCommitStream] yet.
  ///
  /// This method cannot add membership. It returns true only when the durable
  /// canonical ledger has already published an exactly matching record.
  bool commitVerified({
    required String jpegPath,
    required double captureTimestamp,
    required int imageWidth,
    required int imageHeight,
  }) {
    final record = AcceptedPhotoRecordRegistry.byJpegPath(jpegPath);
    return record != null &&
        record.captureTimestamp == captureTimestamp &&
        record.imageWidth == imageWidth &&
        record.imageHeight == imageHeight;
  }

  /// Projection API for new page wiring. The record must already be present
  /// in the durable registry; this never admits an arbitrary record or JPEG.
  bool applyCanonicalRecord(AcceptedPhotoRecord record) =>
      AcceptedPhotoRecordRegistry.byJpegPath(record.jpegPath) == record;

  bool updateAnalysisState(String jpegPath, PhotoCardSfmState analysisState) {
    final record = AcceptedPhotoRecordRegistry.byJpegPath(jpegPath);
    if (record == null ||
        (_analysisByTransaction[record.transactionId] ??
                PhotoCardSfmState.pending) ==
            analysisState) {
      return false;
    }
    _analysisByTransaction[record.transactionId] = analysisState;
    notifyListeners();
    return true;
  }

  /// Membership removal requires a durable tombstone owned by the canonical
  /// store. The album is only a projection and therefore cannot remove it.
  bool remove(String jpegPath) {
    return false;
  }

  /// Clears projection-only analysis state. Durable membership is untouched.
  void clear() {
    if (_analysisByTransaction.isEmpty) return;
    _analysisByTransaction.clear();
    notifyListeners();
  }

  OfficialProjectPhoto _projectPhoto(AcceptedPhotoRecord record) =>
      OfficialProjectPhoto(
        transactionId: record.transactionId,
        jpegPath: record.jpegPath,
        captureTimestamp: record.captureTimestamp,
        analysisState:
            _analysisByTransaction[record.transactionId] ??
            PhotoCardSfmState.pending,
      );

  void _dropOrphanedAnalysisState() {
    final transactionIds = AcceptedPhotoRecordRegistry.snapshot
        .map((record) => record.transactionId)
        .toSet();
    _analysisByTransaction.removeWhere(
      (transactionId, _) => !transactionIds.contains(transactionId),
    );
  }

  @override
  void dispose() {
    unawaited(_registrySubscription.cancel());
    super.dispose();
  }
}
