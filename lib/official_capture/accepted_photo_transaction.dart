import 'dart:async';
import 'dart:convert';

/// Terminal data result for one admitted shutter transaction.
///
/// Data acceptance is deliberately independent from UI feedback. A haptic or
/// preview failure must never retroactively reject a JPEG that already entered
/// the project data pipeline.
enum AcceptedPhotoDataOutcome { pending, accepted, rejected, cancelled }

/// Terminal UI-feedback result for one admitted shutter transaction.
enum AcceptedPhotoPresentationOutcome { pending, presented, failed, suppressed }

AcceptedPhotoPresentationOutcome acceptedPhotoPresentationOutcomeFromReceipt(
  Map<String, Object?>? receipt,
) {
  if (receipt?['rendered'] == true) {
    return AcceptedPhotoPresentationOutcome.presented;
  }
  if (receipt?['suppressed'] == true) {
    return AcceptedPhotoPresentationOutcome.suppressed;
  }
  return AcceptedPhotoPresentationOutcome.failed;
}

/// Durable, replayable consumers of the canonical accepted-photo record.
///
/// A projection is never allowed to decide whether a photo is a project
/// member. Its success receipt or typed debt is stored separately from the
/// immutable [AcceptedPhotoRecord].
enum AcceptedPhotoProjection {
  album,
  actualPhotoGate,
  capture,
  geometry,
  coverage,
  archive,
  sfmInput,
  controller,
}

typedef AcceptedPhotoProjectionHandler =
    FutureOr<void> Function(AcceptedPhotoRecord record);

/// A typed projection failure which is safe to persist in the replay outbox.
class AcceptedPhotoProjectionException implements Exception {
  const AcceptedPhotoProjectionException({
    required this.code,
    required this.message,
  });

  final String code;
  final String message;

  @override
  String toString() => 'AcceptedPhotoProjectionException($code): $message';
}

/// The immutable durable membership row for one accepted 12 MP photo.
///
/// The JPEG is staged first. Publishing this record by same-directory atomic
/// rename is the sole operation that turns that JPEG into project membership.
/// Everything else is a replayable projection keyed by [transactionId].
class AcceptedPhotoRecord {
  AcceptedPhotoRecord({
    required this.transactionId,
    required this.generation,
    required this.frameId,
    required this.jpegPath,
    required this.previewPath,
    required this.automaticSelection,
    required this.imageWidth,
    required this.imageHeight,
    required this.triggerTimestamp,
    required this.captureTimestamp,
    List<double>? requestPose,
    List<double>? evidencePose,
    List<double>? cardPose,
    List<double>? cameraTransform,
    required List<double> intrinsics,
    required this.captureKind,
    required this.poseSyncQuality,
    required this.trackingStateName,
    required this.gray128Base64,
    required Map<String, Object?> sample,
    required Map<String, Object?> quality,
    this.noveltyVerified = true,
    this.schemaVersion = currentSchemaVersion,
  }) : requestPose = List<double>.unmodifiable(
         requestPose ?? cameraTransform ?? const <double>[],
       ),
       evidencePose = List<double>.unmodifiable(
         evidencePose ?? cameraTransform ?? const <double>[],
       ),
       cardPose = List<double>.unmodifiable(
         cardPose ?? requestPose ?? cameraTransform ?? const <double>[],
       ),
       intrinsics = List<double>.unmodifiable(intrinsics),
       sample = _immutableJsonMap(sample),
       quality = _immutableJsonMap(quality);

  static const int currentSchemaVersion = 1;

  final int schemaVersion;
  final String transactionId;
  final int generation;
  final String frameId;
  final String jpegPath;
  final String previewPath;
  final bool automaticSelection;
  final int imageWidth;
  final int imageHeight;
  final double triggerTimestamp;
  final double captureTimestamp;
  final List<double> requestPose;
  final List<double> evidencePose;
  final List<double> cardPose;

  List<double> get cameraTransform => evidencePose;
  final List<double> intrinsics;
  final String captureKind;
  final String poseSyncQuality;
  final String? trackingStateName;
  final String? gray128Base64;
  final Map<String, Object?> sample;
  final Map<String, Object?> quality;

  /// Whether the actual-photo gate verified this photo as a NEW viewpoint.
  ///
  /// A false value never means the photo is unwanted. Upstream VINS-Mono's
  /// `FeatureManager::addFeatureCheckParallax()` returns a marginalization
  /// strategy, not a keep/discard verdict: on `MARGIN_SECOND_NEW` the new
  /// frame is still retained and the dropped frame's IMU is merged forward
  /// (`Estimator::slideWindow`). Reusing that boolean as a delete signal was
  /// the one place this replication diverged from upstream, and it made a
  /// lossless switch lossy. The photo is therefore always recorded; only the
  /// gate's own baseline declines to advance, which is what preserves the
  /// hysteresis that lets a slow pan accumulate past the displacement bar.
  ///
  /// Defaults to true so records written before this field existed — all of
  /// which could only be created on the accepting branch — load unchanged.
  final bool noveltyVerified;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'transactionId': transactionId,
    'generation': generation,
    'frameId': frameId,
    'jpegPath': jpegPath,
    'previewPath': previewPath,
    'automaticSelection': automaticSelection,
    'imageWidth': imageWidth,
    'imageHeight': imageHeight,
    'triggerTimestamp': triggerTimestamp,
    'captureTimestamp': captureTimestamp,
    'requestPose': requestPose,
    'evidencePose': evidencePose,
    'cardPose': cardPose,
    'intrinsics': intrinsics,
    'captureKind': captureKind,
    'poseSyncQuality': poseSyncQuality,
    'trackingStateName': trackingStateName,
    'gray128Base64': gray128Base64,
    'sample': sample,
    'quality': quality,
    'noveltyVerified': noveltyVerified,
  };

  factory AcceptedPhotoRecord.fromJson(Map<String, Object?> json) {
    List<double> doubles(String key) {
      final value = json[key];
      if (value is! List) throw FormatException('$key must be a list');
      return value
          .map((entry) {
            if (entry is! num) throw FormatException('$key must be numeric');
            return entry.toDouble();
          })
          .toList(growable: false);
    }

    Map<String, Object?> map(String key) {
      final value = json[key];
      if (value is! Map) throw FormatException('$key must be an object');
      return value.map((key, value) => MapEntry('$key', value));
    }

    String string(String key) {
      final value = json[key];
      if (value is! String) throw FormatException('$key must be a string');
      return value;
    }

    int integer(String key) {
      final value = json[key];
      if (value is! num) throw FormatException('$key must be numeric');
      return value.toInt();
    }

    double number(String key) {
      final value = json[key];
      if (value is! num) throw FormatException('$key must be numeric');
      return value.toDouble();
    }

    final tracking = json['trackingStateName'];
    final gray = json['gray128Base64'];
    return AcceptedPhotoRecord(
      schemaVersion: integer('schemaVersion'),
      transactionId: string('transactionId'),
      generation: integer('generation'),
      frameId: string('frameId'),
      jpegPath: string('jpegPath'),
      previewPath: string('previewPath'),
      automaticSelection: json['automaticSelection'] == true,
      imageWidth: integer('imageWidth'),
      imageHeight: integer('imageHeight'),
      triggerTimestamp: number('triggerTimestamp'),
      captureTimestamp: number('captureTimestamp'),
      requestPose: json.containsKey('requestPose')
          ? doubles('requestPose')
          : doubles('cameraTransform'),
      evidencePose: json.containsKey('evidencePose')
          ? doubles('evidencePose')
          : doubles('cameraTransform'),
      cardPose: json.containsKey('cardPose')
          ? doubles('cardPose')
          : json.containsKey('requestPose')
          ? doubles('requestPose')
          : doubles('cameraTransform'),
      intrinsics: doubles('intrinsics'),
      captureKind: string('captureKind'),
      poseSyncQuality: string('poseSyncQuality'),
      trackingStateName: tracking is String ? tracking : null,
      gray128Base64: gray is String ? gray : null,
      sample: map('sample'),
      quality: map('quality'),
      // Absent in pre-field records, which were all accepted-branch writes.
      noveltyVerified: json['noveltyVerified'] != false,
    );
  }

  AcceptedPhotoRecord copyWith({
    String? transactionId,
    int? generation,
    String? frameId,
    String? jpegPath,
    String? previewPath,
    bool? automaticSelection,
    int? imageWidth,
    int? imageHeight,
    double? triggerTimestamp,
    double? captureTimestamp,
    List<double>? requestPose,
    List<double>? evidencePose,
    List<double>? cardPose,
    List<double>? intrinsics,
    String? captureKind,
    String? poseSyncQuality,
    String? trackingStateName,
    String? gray128Base64,
    Map<String, Object?>? sample,
    Map<String, Object?>? quality,
    bool? noveltyVerified,
  }) => AcceptedPhotoRecord(
    schemaVersion: schemaVersion,
    transactionId: transactionId ?? this.transactionId,
    generation: generation ?? this.generation,
    frameId: frameId ?? this.frameId,
    jpegPath: jpegPath ?? this.jpegPath,
    previewPath: previewPath ?? this.previewPath,
    automaticSelection: automaticSelection ?? this.automaticSelection,
    imageWidth: imageWidth ?? this.imageWidth,
    imageHeight: imageHeight ?? this.imageHeight,
    triggerTimestamp: triggerTimestamp ?? this.triggerTimestamp,
    captureTimestamp: captureTimestamp ?? this.captureTimestamp,
    requestPose: requestPose ?? this.requestPose,
    evidencePose: evidencePose ?? this.evidencePose,
    cardPose: cardPose ?? this.cardPose,
    intrinsics: intrinsics ?? this.intrinsics,
    captureKind: captureKind ?? this.captureKind,
    poseSyncQuality: poseSyncQuality ?? this.poseSyncQuality,
    trackingStateName: trackingStateName ?? this.trackingStateName,
    gray128Base64: gray128Base64 ?? this.gray128Base64,
    sample: sample ?? this.sample,
    quality: quality ?? this.quality,
    noveltyVerified: noveltyVerified ?? this.noveltyVerified,
  );

  String get canonicalJson => jsonEncode(toJson());

  @override
  bool operator ==(Object other) =>
      other is AcceptedPhotoRecord && canonicalJson == other.canonicalJson;

  @override
  int get hashCode => Object.hash(transactionId, canonicalJson);
}

Map<String, Object?> _immutableJsonMap(Map<String, Object?> source) =>
    Map<String, Object?>.unmodifiable(
      source.map((key, value) => MapEntry(key, _immutableJsonValue(value))),
    );

Object? _immutableJsonValue(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable(
      value.map((key, child) => MapEntry('$key', _immutableJsonValue(child))),
    );
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_immutableJsonValue));
  }
  return value;
}

/// Read-only receipt for one shutter transaction.
///
/// State transitions are owned by [AcceptedPhotoTransactionCoordinator], which
/// gives each outcome exactly-once semantics and seals transactions from an old
/// capture generation.
class AcceptedPhotoTransaction {
  AcceptedPhotoTransaction._({required this.id, required this.generation});

  final String id;
  final int generation;

  AcceptedPhotoDataOutcome _dataOutcome = AcceptedPhotoDataOutcome.pending;
  AcceptedPhotoPresentationOutcome _presentationOutcome =
      AcceptedPhotoPresentationOutcome.pending;
  bool _publicationSubmitted = false;

  AcceptedPhotoDataOutcome get dataOutcome => _dataOutcome;
  AcceptedPhotoPresentationOutcome get presentationOutcome =>
      _presentationOutcome;

  /// True only after the final generation check and immediately before the
  /// durable record rename is submitted. Cleanup must treat this state as
  /// owned until publication succeeds or explicitly fails.
  bool get dataPublicationSubmitted => _publicationSubmitted;
}

/// Generation seal and exactly-once outcome owner for accepted photos.
class AcceptedPhotoTransactionCoordinator {
  int _generation = 0;
  bool _generationOpen = false;
  bool _admissionOpen = false;
  final Map<String, AcceptedPhotoTransaction> _transactions =
      <String, AcceptedPhotoTransaction>{};

  int get currentGeneration => _generation;
  bool get hasOpenGeneration => _generationOpen && _admissionOpen;

  /// Seals any prior generation and returns a fresh generation identifier.
  int openNextGeneration() {
    sealCurrentGeneration();
    _generation++;
    _generationOpen = true;
    _admissionOpen = true;
    return _generation;
  }

  AcceptedPhotoTransaction begin(String id) {
    if (!_generationOpen || !_admissionOpen) {
      throw StateError('Cannot begin a photo transaction in a sealed session');
    }
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'must not be empty');
    }
    final key = _key(_generation, id);
    if (_transactions.containsKey(key)) {
      throw StateError('Duplicate photo transaction id in one generation: $id');
    }
    final transaction = AcceptedPhotoTransaction._(
      id: id,
      generation: _generation,
    );
    _transactions[key] = transaction;
    return transaction;
  }

  /// True only while [transaction] belongs to the currently open generation.
  bool isOpen(AcceptedPhotoTransaction transaction) =>
      _generationOpen &&
      transaction.generation == _generation &&
      identical(
        _transactions[_key(transaction.generation, transaction.id)],
        transaction,
      );

  bool acceptData(AcceptedPhotoTransaction transaction) =>
      _resolveData(transaction, AcceptedPhotoDataOutcome.accepted);

  /// Linearization point immediately before the durable record rename.
  ///
  /// A generation seal after this returns true cannot cancel the publication:
  /// the atomic filesystem operation was already submitted before the seal.
  /// A seal before this call makes it return false and the temp record is
  /// deleted without becoming membership.
  bool beginDataPublication(AcceptedPhotoTransaction transaction) {
    if (!isOpen(transaction) ||
        transaction._dataOutcome != AcceptedPhotoDataOutcome.pending ||
        transaction._publicationSubmitted) {
      return false;
    }
    transaction._publicationSubmitted = true;
    return true;
  }

  /// Ends a failed atomic publication attempt without manufacturing an
  /// accepted result. A concurrently sealed generation becomes cancelled.
  void failDataPublication(AcceptedPhotoTransaction transaction) {
    if (!identical(
          _transactions[_key(transaction.generation, transaction.id)],
          transaction,
        ) ||
        transaction._dataOutcome != AcceptedPhotoDataOutcome.pending) {
      return;
    }
    transaction._publicationSubmitted = false;
    if (!_generationOpen || transaction.generation != _generation) {
      transaction._dataOutcome = AcceptedPhotoDataOutcome.cancelled;
    }
  }

  bool rejectData(AcceptedPhotoTransaction transaction) =>
      _resolveData(transaction, AcceptedPhotoDataOutcome.rejected);

  bool resolvePresentation(
    AcceptedPhotoTransaction transaction,
    AcceptedPhotoPresentationOutcome outcome,
  ) {
    if (outcome == AcceptedPhotoPresentationOutcome.pending ||
        !identical(
          _transactions[_key(transaction.generation, transaction.id)],
          transaction,
        ) ||
        transaction._presentationOutcome !=
            AcceptedPhotoPresentationOutcome.pending) {
      return false;
    }
    transaction._presentationOutcome = outcome;
    return true;
  }

  /// Stops new shutter admissions without cancelling the one transaction that
  /// was already admitted. Finish uses this synchronous boundary before its
  /// first await, then lets that owned transaction reach bounded data and
  /// presentation terminals.
  void sealAdmission() {
    _admissionOpen = false;
  }

  /// Prevents any pending transaction from committing after stop/dispose.
  /// Already accepted or rejected data receipts remain immutable history.
  void sealCurrentGeneration() {
    if (!_generationOpen) return;
    _admissionOpen = false;
    _generationOpen = false;
    for (final transaction in _transactions.values) {
      if (transaction.generation == _generation &&
          transaction._dataOutcome == AcceptedPhotoDataOutcome.pending &&
          !transaction._publicationSubmitted) {
        transaction._dataOutcome = AcceptedPhotoDataOutcome.cancelled;
      }
    }
  }

  bool _resolveData(
    AcceptedPhotoTransaction transaction,
    AcceptedPhotoDataOutcome outcome,
  ) {
    if (outcome == AcceptedPhotoDataOutcome.pending ||
        outcome == AcceptedPhotoDataOutcome.cancelled ||
        (outcome == AcceptedPhotoDataOutcome.rejected &&
            transaction._publicationSubmitted) ||
        !(isOpen(transaction) || transaction._publicationSubmitted) ||
        transaction._dataOutcome != AcceptedPhotoDataOutcome.pending) {
      return false;
    }
    transaction._dataOutcome = outcome;
    return true;
  }

  static String _key(int generation, String id) => '$generation:$id';
}
