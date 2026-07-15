import 'dart:collection';
import 'dart:convert';

/// Ordered evidence stages for one manual capture job.
enum ManualCaptureStage {
  attempted,
  accepted,
  photoCommitted,
  sfmQueued,
  sfmIngested,
  registered,
}

enum _ManualCaptureEventType {
  attempted,
  accepted,
  photoCommitted,
  sfmQueued,
  sfmIngested,
  registered,
  blocked,
  blockerResolved,
  userDeletionRequested,
  writersQuiesced,
  userDeleted,
  reconstructionTainted,
  reconstructionRebuilt,
}

extension on ManualCaptureStage {
  String get wireName => switch (this) {
    ManualCaptureStage.attempted => 'attempted',
    ManualCaptureStage.accepted => 'accepted',
    ManualCaptureStage.photoCommitted => 'photo_committed',
    ManualCaptureStage.sfmQueued => 'sfm_queued',
    ManualCaptureStage.sfmIngested => 'sfm_ingested',
    ManualCaptureStage.registered => 'registered',
  };
}

extension on _ManualCaptureEventType {
  String get wireName => switch (this) {
    _ManualCaptureEventType.attempted => 'attempted',
    _ManualCaptureEventType.accepted => 'accepted',
    _ManualCaptureEventType.photoCommitted => 'photo_committed',
    _ManualCaptureEventType.sfmQueued => 'sfm_queued',
    _ManualCaptureEventType.sfmIngested => 'sfm_ingested',
    _ManualCaptureEventType.registered => 'registered',
    _ManualCaptureEventType.blocked => 'blocked',
    _ManualCaptureEventType.blockerResolved => 'blocker_resolved',
    _ManualCaptureEventType.userDeletionRequested => 'user_deletion_requested',
    _ManualCaptureEventType.writersQuiesced => 'writers_quiesced',
    _ManualCaptureEventType.userDeleted => 'user_deleted',
    _ManualCaptureEventType.reconstructionTainted => 'reconstruction_tainted',
    _ManualCaptureEventType.reconstructionRebuilt => 'reconstruction_rebuilt',
  };

  ManualCaptureStage? get evidenceStage => switch (this) {
    _ManualCaptureEventType.attempted => ManualCaptureStage.attempted,
    _ManualCaptureEventType.accepted => ManualCaptureStage.accepted,
    _ManualCaptureEventType.photoCommitted => ManualCaptureStage.photoCommitted,
    _ManualCaptureEventType.sfmQueued => ManualCaptureStage.sfmQueued,
    _ManualCaptureEventType.sfmIngested => ManualCaptureStage.sfmIngested,
    _ManualCaptureEventType.registered => ManualCaptureStage.registered,
    _ManualCaptureEventType.blocked ||
    _ManualCaptureEventType.blockerResolved ||
    _ManualCaptureEventType.userDeletionRequested ||
    _ManualCaptureEventType.writersQuiesced ||
    _ManualCaptureEventType.userDeleted ||
    _ManualCaptureEventType.reconstructionTainted ||
    _ManualCaptureEventType.reconstructionRebuilt => null,
  };
}

/// A pure lifecycle event. Callers persist its canonical JSON themselves.
final class ManualCaptureEvent {
  ManualCaptureEvent._({
    required this.captureJobId,
    required _ManualCaptureEventType type,
    this.identityToken,
    this.blockerId,
    this.blockerCode,
    this.blockerMessage,
    this.resolutionEvidence,
    this.reconstructionEpochId,
    this.nativeImageId,
    this.mappingEvidenceToken,
    this.taintId,
    this.reasonCode,
    this.evidenceToken,
    this.artifactIdentity,
    Map<String, String>? jobToNativeImageId,
  }) : _type = type,
       _jobToNativeImageId = jobToNativeImageId;

  factory ManualCaptureEvent.attempted({
    required String captureJobId,
    required String identityToken,
  }) {
    return ManualCaptureEvent._(
      captureJobId: _requireNormalizedToken(captureJobId, 'captureJobId'),
      type: _ManualCaptureEventType.attempted,
      identityToken: _requireNormalizedToken(identityToken, 'identityToken'),
    );
  }

  factory ManualCaptureEvent.accepted(String captureJobId) =>
      ManualCaptureEvent._(
        captureJobId: _jobId(captureJobId),
        type: _ManualCaptureEventType.accepted,
      );

  factory ManualCaptureEvent.photoCommitted(String captureJobId) =>
      ManualCaptureEvent._(
        captureJobId: _jobId(captureJobId),
        type: _ManualCaptureEventType.photoCommitted,
      );

  factory ManualCaptureEvent.sfmQueued(String captureJobId) =>
      ManualCaptureEvent._(
        captureJobId: _jobId(captureJobId),
        type: _ManualCaptureEventType.sfmQueued,
      );

  factory ManualCaptureEvent.sfmIngested(String captureJobId) =>
      ManualCaptureEvent._(
        captureJobId: _jobId(captureJobId),
        type: _ManualCaptureEventType.sfmIngested,
      );

  factory ManualCaptureEvent.registered(
    String captureJobId, {
    required String reconstructionEpochId,
    required String nativeImageId,
    required String mappingEvidenceToken,
  }) {
    return ManualCaptureEvent._(
      captureJobId: _jobId(captureJobId),
      type: _ManualCaptureEventType.registered,
      reconstructionEpochId: _requireNormalizedToken(
        reconstructionEpochId,
        'reconstructionEpochId',
      ),
      nativeImageId: _requireNormalizedToken(nativeImageId, 'nativeImageId'),
      mappingEvidenceToken: _requireNormalizedToken(
        mappingEvidenceToken,
        'mappingEvidenceToken',
      ),
    );
  }

  factory ManualCaptureEvent.blocked(
    String captureJobId, {
    required String blockerId,
    required String code,
    required String message,
  }) {
    return ManualCaptureEvent._(
      captureJobId: _jobId(captureJobId),
      type: _ManualCaptureEventType.blocked,
      blockerId: _requireNormalizedToken(blockerId, 'blockerId'),
      blockerCode: _requireNormalizedToken(code, 'code'),
      blockerMessage: _requireMessage(message, 'message'),
    );
  }

  factory ManualCaptureEvent.blockerResolved(
    String captureJobId, {
    required String blockerId,
    required String resolutionEvidence,
  }) {
    return ManualCaptureEvent._(
      captureJobId: _jobId(captureJobId),
      type: _ManualCaptureEventType.blockerResolved,
      blockerId: _requireNormalizedToken(blockerId, 'blockerId'),
      resolutionEvidence: _requireResolutionEvidence(
        resolutionEvidence,
        'resolutionEvidence',
      ),
    );
  }

  factory ManualCaptureEvent.userDeletionRequested(String captureJobId) =>
      ManualCaptureEvent._(
        captureJobId: _jobId(captureJobId),
        type: _ManualCaptureEventType.userDeletionRequested,
      );

  factory ManualCaptureEvent.writersQuiesced(
    String captureJobId, {
    required String evidenceToken,
  }) {
    return ManualCaptureEvent._(
      captureJobId: _jobId(captureJobId),
      type: _ManualCaptureEventType.writersQuiesced,
      evidenceToken: _requireNormalizedToken(evidenceToken, 'evidenceToken'),
    );
  }

  factory ManualCaptureEvent.userDeleted(String captureJobId) =>
      ManualCaptureEvent._(
        captureJobId: _jobId(captureJobId),
        type: _ManualCaptureEventType.userDeleted,
      );

  factory ManualCaptureEvent.reconstructionTainted(
    String captureJobId, {
    required String taintId,
    required String reasonCode,
    required String evidenceToken,
  }) {
    return ManualCaptureEvent._(
      captureJobId: _jobId(captureJobId),
      type: _ManualCaptureEventType.reconstructionTainted,
      taintId: _requireNormalizedToken(taintId, 'taintId'),
      reasonCode: _requireNormalizedToken(reasonCode, 'reasonCode'),
      evidenceToken: _requireNormalizedToken(evidenceToken, 'evidenceToken'),
    );
  }

  /// Records an `add_frame` outcome that may have partially mutated native
  /// reconstruction state but cannot prove successful ingestion.
  factory ManualCaptureEvent.nativeIngestAmbiguous(
    String captureJobId, {
    required String taintId,
    required String reasonCode,
    required String evidenceToken,
  }) => ManualCaptureEvent.reconstructionTainted(
    captureJobId,
    taintId: taintId,
    reasonCode: reasonCode,
    evidenceToken: evidenceToken,
  );

  factory ManualCaptureEvent.reconstructionRebuilt({
    required String reconstructionEpochId,
    required String artifactIdentity,
    required String evidenceToken,
    required Map<String, String> jobToNativeImageId,
  }) {
    return ManualCaptureEvent._(
      captureJobId: null,
      type: _ManualCaptureEventType.reconstructionRebuilt,
      reconstructionEpochId: _requireNormalizedToken(
        reconstructionEpochId,
        'reconstructionEpochId',
      ),
      artifactIdentity: _requireNormalizedToken(
        artifactIdentity,
        'artifactIdentity',
      ),
      evidenceToken: _requireNormalizedToken(evidenceToken, 'evidenceToken'),
      jobToNativeImageId: _validatedJobToNativeImageId(
        jobToNativeImageId,
        'jobToNativeImageId',
      ),
    );
  }

  static const int schemaVersion = 1;

  final String? captureJobId;
  final _ManualCaptureEventType _type;
  final String? identityToken;
  final String? blockerId;
  final String? blockerCode;
  final String? blockerMessage;
  final String? resolutionEvidence;
  final String? reconstructionEpochId;
  final String? nativeImageId;
  final String? mappingEvidenceToken;
  final String? taintId;
  final String? reasonCode;
  final String? evidenceToken;
  final String? artifactIdentity;
  final Map<String, String>? _jobToNativeImageId;

  Map<String, String>? get jobToNativeImageId => _jobToNativeImageId == null
      ? null
      : UnmodifiableMapView(_jobToNativeImageId);

  Map<String, Object?> toJson() => <String, Object?>{
    'schema_version': schemaVersion,
    if (captureJobId != null) 'capture_job_id': captureJobId,
    'event': _type.wireName,
    if (identityToken != null) 'identity_token': identityToken,
    if (blockerId != null) 'blocker_id': blockerId,
    if (blockerCode != null) 'blocker_code': blockerCode,
    if (blockerMessage != null) 'blocker_message': blockerMessage,
    if (resolutionEvidence != null) 'resolution_evidence': resolutionEvidence,
    if (reconstructionEpochId != null)
      'reconstruction_epoch_id': reconstructionEpochId,
    if (nativeImageId != null) 'native_image_id': nativeImageId,
    if (mappingEvidenceToken != null)
      'mapping_evidence_token': mappingEvidenceToken,
    if (taintId != null) 'taint_id': taintId,
    if (reasonCode != null) 'reason_code': reasonCode,
    if (evidenceToken != null) 'evidence_token': evidenceToken,
    if (artifactIdentity != null) 'artifact_identity': artifactIdentity,
    if (_jobToNativeImageId != null)
      'job_to_native_image_id': _jobToNativeImageId,
  };

  String toCanonicalJson() => _canonicalJson(toJson());
}

final class ManualCaptureBlocker {
  const ManualCaptureBlocker({
    required this.blockerId,
    required this.code,
    required this.message,
  });

  final String blockerId;
  final String code;
  final String message;

  Map<String, Object?> toJson() => <String, Object?>{
    'blocker_id': blockerId,
    'code': code,
    'message': message,
  };
}

final class ManualCaptureBlockerResolution {
  const ManualCaptureBlockerResolution({
    required this.blockerId,
    required this.code,
    required this.resolutionEvidence,
  });

  final String blockerId;
  final String code;
  final String resolutionEvidence;

  Map<String, Object?> toJson() => <String, Object?>{
    'blocker_id': blockerId,
    'code': code,
    'resolution_evidence': resolutionEvidence,
  };
}

final class ManualCaptureRegistrationMapping {
  const ManualCaptureRegistrationMapping({
    required this.reconstructionEpochId,
    required this.nativeImageId,
    required this.evidenceToken,
  });

  final String reconstructionEpochId;
  final String nativeImageId;
  final String evidenceToken;

  bool matches(ManualCaptureEvent event) =>
      reconstructionEpochId == event.reconstructionEpochId &&
      nativeImageId == event.nativeImageId &&
      evidenceToken == event.mappingEvidenceToken;

  Map<String, Object?> toJson() => <String, Object?>{
    'reconstruction_epoch_id': reconstructionEpochId,
    'native_image_id': nativeImageId,
    'evidence_token': evidenceToken,
  };
}

/// Immutable snapshot of one capture job's proven lifecycle.
final class ManualCaptureJob {
  const ManualCaptureJob._({
    required this.captureJobId,
    required this.identityToken,
    required this.stage,
    required this.registrationMapping,
    required this.deletionRequested,
    required this.writersQuiescedEvidence,
    required this.userDeleted,
    required Map<String, ManualCaptureBlocker> blockers,
    required Map<String, ManualCaptureBlockerResolution> resolvedBlockers,
  }) : _blockers = blockers,
       _resolvedBlockers = resolvedBlockers;

  final String captureJobId;
  final String identityToken;
  final ManualCaptureStage stage;
  final ManualCaptureRegistrationMapping? registrationMapping;
  final bool deletionRequested;
  final String? writersQuiescedEvidence;
  final bool userDeleted;
  final Map<String, ManualCaptureBlocker> _blockers;
  final Map<String, ManualCaptureBlockerResolution> _resolvedBlockers;

  bool get attempted => true;
  bool get accepted => stage.index >= ManualCaptureStage.accepted.index;
  bool get photoCommitted =>
      stage.index >= ManualCaptureStage.photoCommitted.index;
  bool get sfmQueued => stage.index >= ManualCaptureStage.sfmQueued.index;
  bool get sfmIngested => stage.index >= ManualCaptureStage.sfmIngested.index;
  bool get registered => stage.index >= ManualCaptureStage.registered.index;
  bool get writersQuiesced => writersQuiescedEvidence != null;
  bool get blocked => _blockers.isNotEmpty;

  Map<String, ManualCaptureBlocker> get blockers =>
      UnmodifiableMapView(_blockers);
  Map<String, ManualCaptureBlockerResolution> get resolvedBlockers =>
      UnmodifiableMapView(_resolvedBlockers);

  ManualCaptureJob _copy({
    ManualCaptureStage? stage,
    ManualCaptureRegistrationMapping? registrationMapping,
    bool preserveRegistrationMapping = true,
    bool? deletionRequested,
    String? writersQuiescedEvidence,
    bool preserveWritersQuiescedEvidence = true,
    bool? userDeleted,
    Map<String, ManualCaptureBlocker>? blockers,
    Map<String, ManualCaptureBlockerResolution>? resolvedBlockers,
  }) {
    return ManualCaptureJob._(
      captureJobId: captureJobId,
      identityToken: identityToken,
      stage: stage ?? this.stage,
      registrationMapping: preserveRegistrationMapping
          ? (registrationMapping ?? this.registrationMapping)
          : registrationMapping,
      deletionRequested: deletionRequested ?? this.deletionRequested,
      writersQuiescedEvidence: preserveWritersQuiescedEvidence
          ? (writersQuiescedEvidence ?? this.writersQuiescedEvidence)
          : writersQuiescedEvidence,
      userDeleted: userDeleted ?? this.userDeleted,
      blockers: blockers ?? _blockers,
      resolvedBlockers: resolvedBlockers ?? _resolvedBlockers,
    );
  }

  ManualCaptureJob _withStage(
    ManualCaptureStage nextStage, {
    ManualCaptureRegistrationMapping? mapping,
  }) => _copy(stage: nextStage, registrationMapping: mapping);

  ManualCaptureJob _withCleanRebuildMapping(
    ManualCaptureRegistrationMapping mapping,
  ) => _copy(
    stage: ManualCaptureStage.registered,
    registrationMapping: mapping,
    preserveRegistrationMapping: false,
  );

  ManualCaptureJob _withBlocker(ManualCaptureBlocker blocker) => _copy(
    blockers: Map<String, ManualCaptureBlocker>.unmodifiable(
      <String, ManualCaptureBlocker>{..._blockers, blocker.blockerId: blocker},
    ),
  );

  ManualCaptureJob _withResolvedBlocker(
    ManualCaptureBlocker blocker,
    String resolutionEvidence,
  ) {
    final remaining = <String, ManualCaptureBlocker>{..._blockers}
      ..remove(blocker.blockerId);
    return _copy(
      blockers: Map<String, ManualCaptureBlocker>.unmodifiable(remaining),
      resolvedBlockers:
          Map<String, ManualCaptureBlockerResolution>.unmodifiable(
            <String, ManualCaptureBlockerResolution>{
              ..._resolvedBlockers,
              blocker.blockerId: ManualCaptureBlockerResolution(
                blockerId: blocker.blockerId,
                code: blocker.code,
                resolutionEvidence: resolutionEvidence,
              ),
            },
          ),
    );
  }

  Map<String, Object?> toJson() {
    final blockerList = _blockers.values.toList()
      ..sort((left, right) => left.blockerId.compareTo(right.blockerId));
    final resolvedList = _resolvedBlockers.values.toList()
      ..sort((left, right) => left.blockerId.compareTo(right.blockerId));
    return <String, Object?>{
      'capture_job_id': captureJobId,
      'identity_token': identityToken,
      'stage': stage.wireName,
      'registration_mapping': registrationMapping?.toJson(),
      'deletion_requested': deletionRequested,
      'writers_quiesced': writersQuiesced,
      'writers_quiesced_evidence': writersQuiescedEvidence,
      'user_deleted': userDeleted,
      'blocked': blocked,
      'blockers': blockerList.map((value) => value.toJson()).toList(),
      'resolved_blockers': resolvedList.map((value) => value.toJson()).toList(),
    };
  }
}

final class ManualCaptureReconstructionTaint {
  const ManualCaptureReconstructionTaint._({
    required this.captureJobId,
    required this.taintId,
    required this.reasonCode,
    required this.evidenceToken,
    required this.reconstructionEpochIdAtDetection,
    required this.resolvedByReconstructionEpochId,
    required this.resolutionEvidenceToken,
  });

  factory ManualCaptureReconstructionTaint.fromEvent(
    ManualCaptureEvent event, {
    required String? reconstructionEpochIdAtDetection,
  }) => ManualCaptureReconstructionTaint._(
    captureJobId: event.captureJobId!,
    taintId: event.taintId!,
    reasonCode: event.reasonCode!,
    evidenceToken: event.evidenceToken!,
    reconstructionEpochIdAtDetection: reconstructionEpochIdAtDetection,
    resolvedByReconstructionEpochId: null,
    resolutionEvidenceToken: null,
  );

  final String captureJobId;
  final String taintId;
  final String reasonCode;
  final String evidenceToken;
  final String? reconstructionEpochIdAtDetection;
  final String? resolvedByReconstructionEpochId;
  final String? resolutionEvidenceToken;

  bool matchesEvent(ManualCaptureEvent event) =>
      captureJobId == event.captureJobId &&
      taintId == event.taintId &&
      reasonCode == event.reasonCode &&
      evidenceToken == event.evidenceToken;

  ManualCaptureReconstructionTaint resolvedBy(ManualCaptureEvent event) =>
      ManualCaptureReconstructionTaint._(
        captureJobId: captureJobId,
        taintId: taintId,
        reasonCode: reasonCode,
        evidenceToken: evidenceToken,
        reconstructionEpochIdAtDetection: reconstructionEpochIdAtDetection,
        resolvedByReconstructionEpochId: event.reconstructionEpochId!,
        resolutionEvidenceToken: event.evidenceToken!,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'capture_job_id': captureJobId,
    'taint_id': taintId,
    'reason_code': reasonCode,
    'evidence_token': evidenceToken,
    if (reconstructionEpochIdAtDetection != null)
      'reconstruction_epoch_id_at_detection': reconstructionEpochIdAtDetection,
    if (resolvedByReconstructionEpochId != null)
      'resolved_by_reconstruction_epoch_id': resolvedByReconstructionEpochId,
    if (resolutionEvidenceToken != null)
      'resolution_evidence_token': resolutionEvidenceToken,
  };
}

final class ManualCaptureRebuildEvidence {
  ManualCaptureRebuildEvidence({
    required this.reconstructionEpochId,
    required this.artifactIdentity,
    required this.evidenceToken,
    required Map<String, String> jobToNativeImageId,
  }) : jobToNativeImageId = _validatedJobToNativeImageId(
         jobToNativeImageId,
         'jobToNativeImageId',
       );

  final String reconstructionEpochId;
  final String artifactIdentity;
  final String evidenceToken;
  final Map<String, String> jobToNativeImageId;

  Set<String> get activeJobIds => _orderedSet(jobToNativeImageId.keys);

  bool matchesEvent(ManualCaptureEvent event) =>
      reconstructionEpochId == event.reconstructionEpochId &&
      artifactIdentity == event.artifactIdentity &&
      evidenceToken == event.evidenceToken &&
      _mapEquals(jobToNativeImageId, event._jobToNativeImageId!);

  Map<String, Object?> toJson() => <String, Object?>{
    'reconstruction_epoch_id': reconstructionEpochId,
    'artifact_identity': artifactIdentity,
    'evidence_token': evidenceToken,
    'job_to_native_image_id': jobToNativeImageId,
  };
}

/// Typed observation of the actual final-registration artifact.
final class FinalRegistrationObservation {
  FinalRegistrationObservation({
    required String artifactIdentity,
    required String evidenceToken,
    required String reconstructionEpochId,
    required Map<String, String> jobToNativeImageId,
  }) : artifactIdentity = _requireNormalizedToken(
         artifactIdentity,
         'artifactIdentity',
       ),
       evidenceToken = _requireNormalizedToken(evidenceToken, 'evidenceToken'),
       reconstructionEpochId = _requireNormalizedToken(
         reconstructionEpochId,
         'reconstructionEpochId',
       ),
       jobToNativeImageId = _validatedJobToNativeImageId(
         jobToNativeImageId,
         'jobToNativeImageId',
       );

  final String artifactIdentity;
  final String evidenceToken;
  final String reconstructionEpochId;
  final Map<String, String> jobToNativeImageId;

  Set<String> get registeredJobIds => _orderedSet(jobToNativeImageId.keys);

  Map<String, Object?> toJson() => <String, Object?>{
    'artifact_identity': artifactIdentity,
    'evidence_token': evidenceToken,
    'reconstruction_epoch_id': reconstructionEpochId,
    'job_to_native_image_id': jobToNativeImageId,
  };

  String toCanonicalJson() => _canonicalJson(toJson());
}

/// An immutable, append-only-in-memory reducer for manual capture evidence.
final class ManualCaptureLedger {
  const ManualCaptureLedger.empty()
    : _jobs = const <String, ManualCaptureJob>{},
      _events = const <ManualCaptureEvent>[],
      _pendingRebuildDeletedJobIds = const <String>{},
      _latestRebuildEvidence = null,
      _currentReconstructionEpochId = null,
      _currentEpochMappings =
          const <String, ManualCaptureRegistrationMapping>{},
      _activeReconstructionTaints =
          const <String, ManualCaptureReconstructionTaint>{},
      _resolvedReconstructionTaints =
          const <String, ManualCaptureReconstructionTaint>{};

  const ManualCaptureLedger._({
    required Map<String, ManualCaptureJob> jobs,
    required List<ManualCaptureEvent> events,
    required Set<String> pendingRebuildDeletedJobIds,
    required ManualCaptureRebuildEvidence? latestRebuildEvidence,
    required String? currentReconstructionEpochId,
    required Map<String, ManualCaptureRegistrationMapping> currentEpochMappings,
    required Map<String, ManualCaptureReconstructionTaint>
    activeReconstructionTaints,
    required Map<String, ManualCaptureReconstructionTaint>
    resolvedReconstructionTaints,
  }) : _jobs = jobs,
       _events = events,
       _pendingRebuildDeletedJobIds = pendingRebuildDeletedJobIds,
       _latestRebuildEvidence = latestRebuildEvidence,
       _currentReconstructionEpochId = currentReconstructionEpochId,
       _currentEpochMappings = currentEpochMappings,
       _activeReconstructionTaints = activeReconstructionTaints,
       _resolvedReconstructionTaints = resolvedReconstructionTaints;

  static const int schemaVersion = 1;

  final Map<String, ManualCaptureJob> _jobs;
  final List<ManualCaptureEvent> _events;
  final Set<String> _pendingRebuildDeletedJobIds;
  final ManualCaptureRebuildEvidence? _latestRebuildEvidence;
  final String? _currentReconstructionEpochId;
  final Map<String, ManualCaptureRegistrationMapping> _currentEpochMappings;
  final Map<String, ManualCaptureReconstructionTaint>
  _activeReconstructionTaints;
  final Map<String, ManualCaptureReconstructionTaint>
  _resolvedReconstructionTaints;

  Map<String, ManualCaptureJob> get jobs => UnmodifiableMapView(_jobs);
  List<ManualCaptureEvent> get events => UnmodifiableListView(_events);
  Set<String> get pendingRebuildDeletedJobIds =>
      UnmodifiableSetView(_pendingRebuildDeletedJobIds);
  bool get rebuildRequired =>
      _pendingRebuildDeletedJobIds.isNotEmpty ||
      _activeReconstructionTaints.isNotEmpty;
  bool get reconstructionTainted => _activeReconstructionTaints.isNotEmpty;
  ManualCaptureRebuildEvidence? get latestRebuildEvidence =>
      _latestRebuildEvidence;
  String? get currentReconstructionEpochId => _currentReconstructionEpochId;
  Map<String, String> get currentJobToNativeImageId =>
      Map<String, String>.unmodifiable(
        SplayTreeMap<String, String>.of(<String, String>{
          for (final entry in _currentEpochMappings.entries)
            entry.key: entry.value.nativeImageId,
        }),
      );
  Map<String, ManualCaptureReconstructionTaint>
  get activeReconstructionTaints =>
      UnmodifiableMapView(_activeReconstructionTaints);
  Map<String, ManualCaptureReconstructionTaint>
  get resolvedReconstructionTaints =>
      UnmodifiableMapView(_resolvedReconstructionTaints);

  ManualCaptureJob? job(String captureJobId) => _jobs[captureJobId];

  ManualCaptureLedger reduce(ManualCaptureEvent event) {
    if (event._type == _ManualCaptureEventType.reconstructionRebuilt) {
      return _reduceReconstructionRebuilt(event);
    }

    final captureJobId = event.captureJobId!;
    final existing = _jobs[captureJobId];
    if (event._type == _ManualCaptureEventType.attempted) {
      if (existing != null) {
        if (existing.identityToken != event.identityToken) {
          throw ManualCaptureLedgerViolation(
            'capture_job_id $captureJobId was reused with a different '
            'identity token.',
          );
        }
        return this;
      }
      final identityOwner = _jobs.values
          .where((job) => job.identityToken == event.identityToken)
          .firstOrNull;
      if (identityOwner != null) {
        throw ManualCaptureLedgerViolation(
          'identity_token ${event.identityToken} already belongs to '
          'capture_job_id ${identityOwner.captureJobId}.',
        );
      }
      return _replaceJob(
        ManualCaptureJob._(
          captureJobId: captureJobId,
          identityToken: event.identityToken!,
          stage: ManualCaptureStage.attempted,
          registrationMapping: null,
          deletionRequested: false,
          writersQuiescedEvidence: null,
          userDeleted: false,
          blockers: const <String, ManualCaptureBlocker>{},
          resolvedBlockers: const <String, ManualCaptureBlockerResolution>{},
        ),
        event,
      );
    }

    if (existing == null) {
      throw ManualCaptureLedgerViolation(
        'Event ${event._type.wireName} references unknown capture_job_id '
        '$captureJobId.',
      );
    }

    if (existing.userDeleted) {
      return _reduceAfterDeletion(existing, event);
    }

    final targetStage = event._type.evidenceStage;
    if (existing.writersQuiesced &&
        targetStage != null &&
        targetStage.index > existing.stage.index) {
      throw ManualCaptureLedgerViolation(
        'capture_job_id $captureJobId cannot advance after writer-quiescence '
        'evidence.',
      );
    }

    switch (event._type) {
      case _ManualCaptureEventType.userDeletionRequested:
        if (existing.deletionRequested) return this;
        return _replaceJob(existing._copy(deletionRequested: true), event);
      case _ManualCaptureEventType.writersQuiesced:
        if (!existing.deletionRequested) {
          throw ManualCaptureLedgerViolation(
            'Writers cannot quiesce before deletion is requested for '
            'capture_job_id $captureJobId.',
          );
        }
        if (existing.writersQuiescedEvidence != null) {
          if (existing.writersQuiescedEvidence == event.evidenceToken) {
            return this;
          }
          throw ManualCaptureLedgerViolation(
            'Writer-quiescence evidence conflicts for capture_job_id '
            '$captureJobId.',
          );
        }
        return _replaceJob(
          existing._copy(writersQuiescedEvidence: event.evidenceToken),
          event,
        );
      case _ManualCaptureEventType.userDeleted:
        if (!existing.deletionRequested || !existing.writersQuiesced) {
          throw ManualCaptureLedgerViolation(
            'capture_job_id $captureJobId cannot be tombstoned before an '
            'explicit request and writer-quiescence evidence.',
          );
        }
        final pending = <String>{..._pendingRebuildDeletedJobIds};
        if (existing.sfmIngested ||
            _currentEpochMappings.containsKey(captureJobId)) {
          pending.add(captureJobId);
        }
        return _replaceJob(
          existing._copy(userDeleted: true),
          event,
          pendingRebuildDeletedJobIds: pending,
        );
      case _ManualCaptureEventType.blockerResolved:
        return _reduceBlockerResolution(existing, event);
      case _ManualCaptureEventType.blocked:
        return _reduceBlocker(existing, event);
      case _ManualCaptureEventType.reconstructionTainted:
        return _reduceReconstructionTainted(existing, event);
      case _ManualCaptureEventType.registered:
        return _reduceRegistered(existing, event);
      case _ManualCaptureEventType.accepted ||
          _ManualCaptureEventType.photoCommitted ||
          _ManualCaptureEventType.sfmQueued ||
          _ManualCaptureEventType.sfmIngested:
        return _reduceEvidenceStage(existing, event);
      case _ManualCaptureEventType.attempted ||
          _ManualCaptureEventType.reconstructionRebuilt:
        throw StateError('handled before switch');
    }
  }

  ManualCaptureLedger _reduceAfterDeletion(
    ManualCaptureJob existing,
    ManualCaptureEvent event,
  ) {
    switch (event._type) {
      case _ManualCaptureEventType.userDeleted:
      case _ManualCaptureEventType.userDeletionRequested:
        return this;
      case _ManualCaptureEventType.writersQuiesced:
        if (existing.writersQuiescedEvidence == event.evidenceToken) {
          return this;
        }
        throw ManualCaptureLedgerViolation(
          'Writer-quiescence evidence conflicts for deleted capture_job_id '
          '${existing.captureJobId}.',
        );
      default:
        throw ManualCaptureLedgerViolation(
          'Deleted capture_job_id ${existing.captureJobId} cannot be '
          'modified or resurrected.',
        );
    }
  }

  ManualCaptureLedger _reduceBlocker(
    ManualCaptureJob existing,
    ManualCaptureEvent event,
  ) {
    final prior = existing._blockers[event.blockerId];
    if (prior != null) {
      if (prior.code == event.blockerCode &&
          prior.message == event.blockerMessage) {
        return this;
      }
      throw ManualCaptureLedgerViolation(
        'blocker_id ${event.blockerId} conflicts with active evidence for '
        'capture_job_id ${existing.captureJobId}.',
      );
    }
    if (existing._resolvedBlockers.containsKey(event.blockerId)) {
      throw ManualCaptureLedgerViolation(
        'Resolved blocker occurrence ${event.blockerId} cannot be reused for '
        'capture_job_id ${existing.captureJobId}.',
      );
    }
    return _replaceJob(
      existing._withBlocker(
        ManualCaptureBlocker(
          blockerId: event.blockerId!,
          code: event.blockerCode!,
          message: event.blockerMessage!,
        ),
      ),
      event,
    );
  }

  ManualCaptureLedger _reduceBlockerResolution(
    ManualCaptureJob existing,
    ManualCaptureEvent event,
  ) {
    final priorResolution = existing._resolvedBlockers[event.blockerId];
    if (priorResolution != null) {
      if (priorResolution.resolutionEvidence == event.resolutionEvidence) {
        return this;
      }
      throw ManualCaptureLedgerViolation(
        'Resolution for blocker occurrence ${event.blockerId} conflicts for '
        'capture_job_id ${existing.captureJobId}.',
      );
    }
    final active = existing._blockers[event.blockerId];
    if (active == null) {
      throw ManualCaptureLedgerViolation(
        'Cannot resolve unknown active blocker occurrence ${event.blockerId} '
        'for capture_job_id ${existing.captureJobId}.',
      );
    }
    return _replaceJob(
      existing._withResolvedBlocker(active, event.resolutionEvidence!),
      event,
    );
  }

  ManualCaptureLedger _reduceReconstructionTainted(
    ManualCaptureJob existing,
    ManualCaptureEvent event,
  ) {
    final active = _activeReconstructionTaints[event.taintId];
    if (active != null) {
      if (active.matchesEvent(event)) return this;
      throw ManualCaptureLedgerViolation(
        'taint_id ${event.taintId} conflicts with active reconstruction '
        'taint evidence.',
      );
    }
    final resolved = _resolvedReconstructionTaints[event.taintId];
    if (resolved != null) {
      if (resolved.matchesEvent(event)) return this;
      throw ManualCaptureLedgerViolation(
        'taint_id ${event.taintId} conflicts with resolved reconstruction '
        'taint evidence.',
      );
    }
    if (existing.stage != ManualCaptureStage.sfmQueued) {
      throw ManualCaptureLedgerViolation(
        'Ambiguous native ingestion must be recorded after sfm_queued and '
        'before sfm_ingested evidence for capture_job_id '
        '${existing.captureJobId}.',
      );
    }
    final taint = ManualCaptureReconstructionTaint.fromEvent(
      event,
      reconstructionEpochIdAtDetection: _currentReconstructionEpochId,
    );
    return _copyLedger(
      event: event,
      activeReconstructionTaints:
          Map<String, ManualCaptureReconstructionTaint>.unmodifiable(
            SplayTreeMap<String, ManualCaptureReconstructionTaint>.of(
              <String, ManualCaptureReconstructionTaint>{
                ..._activeReconstructionTaints,
                taint.taintId: taint,
              },
            ),
          ),
    );
  }

  ManualCaptureLedger _reduceRegistered(
    ManualCaptureJob existing,
    ManualCaptureEvent event,
  ) {
    if (_currentReconstructionEpochId != null &&
        _currentReconstructionEpochId != event.reconstructionEpochId) {
      throw ManualCaptureLedgerViolation(
        'Registration epoch ${event.reconstructionEpochId} does not match '
        'current reconstruction epoch $_currentReconstructionEpochId.',
      );
    }
    final nativeImageOwner = _currentEpochMappings.entries
        .where(
          (entry) =>
              entry.key != existing.captureJobId &&
              entry.value.nativeImageId == event.nativeImageId,
        )
        .firstOrNull;
    if (nativeImageOwner != null) {
      throw ManualCaptureLedgerViolation(
        'native_image_id ${event.nativeImageId} already maps to '
        'capture_job_id ${nativeImageOwner.key}.',
      );
    }
    if (existing.registered) {
      if (existing.registrationMapping!.matches(event)) return this;
      throw ManualCaptureLedgerViolation(
        'Registration mapping conflicts for capture_job_id '
        '${existing.captureJobId}.',
      );
    }
    final mapping = ManualCaptureRegistrationMapping(
      reconstructionEpochId: event.reconstructionEpochId!,
      nativeImageId: event.nativeImageId!,
      evidenceToken: event.mappingEvidenceToken!,
    );
    return _advanceStage(existing, event, mapping: mapping);
  }

  ManualCaptureLedger _reduceEvidenceStage(
    ManualCaptureJob existing,
    ManualCaptureEvent event,
  ) => _advanceStage(existing, event);

  ManualCaptureLedger _advanceStage(
    ManualCaptureJob existing,
    ManualCaptureEvent event, {
    ManualCaptureRegistrationMapping? mapping,
  }) {
    final targetStage = event._type.evidenceStage!;
    if (targetStage.index <= existing.stage.index) return this;
    if (_activeReconstructionTaints.isNotEmpty &&
        targetStage.index >= ManualCaptureStage.sfmIngested.index) {
      throw ManualCaptureLedgerViolation(
        'Event ${event._type.wireName} for capture_job_id '
        '${existing.captureJobId} cannot advance while native reconstruction '
        'state is tainted; exact clean replay evidence is required.',
      );
    }
    if (targetStage.index != existing.stage.index + 1) {
      throw ManualCaptureLedgerViolation(
        'Event ${event._type.wireName} for capture_job_id '
        '${existing.captureJobId} skips required evidence after '
        '${existing.stage.wireName}.',
      );
    }
    final nextMappings = mapping == null
        ? null
        : Map<String, ManualCaptureRegistrationMapping>.unmodifiable(
            SplayTreeMap<String, ManualCaptureRegistrationMapping>.of(
              <String, ManualCaptureRegistrationMapping>{
                ..._currentEpochMappings,
                existing.captureJobId: mapping,
              },
            ),
          );
    return _replaceJob(
      existing._withStage(targetStage, mapping: mapping),
      event,
      currentReconstructionEpochId:
          mapping?.reconstructionEpochId ?? _currentReconstructionEpochId,
      currentEpochMappings: nextMappings,
    );
  }

  ManualCaptureLedger _reduceReconstructionRebuilt(ManualCaptureEvent event) {
    if (!rebuildRequired) {
      if (_latestRebuildEvidence?.matchesEvent(event) ?? false) return this;
      throw ManualCaptureLedgerViolation(
        'No reconstruction rebuild is currently required.',
      );
    }
    if (_latestRebuildEvidence?.matchesEvent(event) ?? false) {
      throw ManualCaptureLedgerViolation(
        'Previously consumed rebuild evidence cannot resolve later taint or '
        'deletion evidence.',
      );
    }
    if (_currentReconstructionEpochId == event.reconstructionEpochId) {
      throw ManualCaptureLedgerViolation(
        'A clean rebuild must introduce a new reconstruction epoch.',
      );
    }
    final expected = _expectedIds();
    if (!_setEquals(expected, event._jobToNativeImageId!.keys.toSet())) {
      throw ManualCaptureLedgerViolation(
        'Rebuild job_to_native_image_id keys do not equal the current active '
        'denominator.',
      );
    }
    final notQueued = expected.where((jobId) => !_jobs[jobId]!.sfmQueued);
    if (notQueued.isNotEmpty) {
      throw ManualCaptureLedgerViolation(
        'Clean replay requires sfm_queued evidence for every active job; '
        'missing: ${notQueued.join(', ')}.',
      );
    }

    final nextMappings =
        SplayTreeMap<String, ManualCaptureRegistrationMapping>();
    final nextJobs = <String, ManualCaptureJob>{..._jobs};
    for (final entry in event._jobToNativeImageId.entries) {
      final mapping = ManualCaptureRegistrationMapping(
        reconstructionEpochId: event.reconstructionEpochId!,
        nativeImageId: entry.value,
        evidenceToken: event.evidenceToken!,
      );
      nextMappings[entry.key] = mapping;
      nextJobs[entry.key] = _jobs[entry.key]!._withCleanRebuildMapping(mapping);
    }

    final resolvedTaints =
        SplayTreeMap<String, ManualCaptureReconstructionTaint>.of(
          _resolvedReconstructionTaints,
        );
    for (final taint in _activeReconstructionTaints.values) {
      resolvedTaints[taint.taintId] = taint.resolvedBy(event);
    }
    final evidence = ManualCaptureRebuildEvidence(
      reconstructionEpochId: event.reconstructionEpochId!,
      artifactIdentity: event.artifactIdentity!,
      evidenceToken: event.evidenceToken!,
      jobToNativeImageId: event._jobToNativeImageId,
    );
    return ManualCaptureLedger._(
      jobs: Map<String, ManualCaptureJob>.unmodifiable(nextJobs),
      events: List<ManualCaptureEvent>.unmodifiable(<ManualCaptureEvent>[
        ..._events,
        event,
      ]),
      pendingRebuildDeletedJobIds: const <String>{},
      latestRebuildEvidence: evidence,
      currentReconstructionEpochId: event.reconstructionEpochId,
      currentEpochMappings:
          Map<String, ManualCaptureRegistrationMapping>.unmodifiable(
            nextMappings,
          ),
      activeReconstructionTaints:
          const <String, ManualCaptureReconstructionTaint>{},
      resolvedReconstructionTaints:
          Map<String, ManualCaptureReconstructionTaint>.unmodifiable(
            resolvedTaints,
          ),
    );
  }

  ManualCaptureLedger _replaceJob(
    ManualCaptureJob replacement,
    ManualCaptureEvent event, {
    Set<String>? pendingRebuildDeletedJobIds,
    String? currentReconstructionEpochId,
    Map<String, ManualCaptureRegistrationMapping>? currentEpochMappings,
  }) {
    return ManualCaptureLedger._(
      jobs: Map<String, ManualCaptureJob>.unmodifiable(
        <String, ManualCaptureJob>{
          ..._jobs,
          replacement.captureJobId: replacement,
        },
      ),
      events: List<ManualCaptureEvent>.unmodifiable(<ManualCaptureEvent>[
        ..._events,
        event,
      ]),
      pendingRebuildDeletedJobIds: _orderedSet(
        pendingRebuildDeletedJobIds ?? _pendingRebuildDeletedJobIds,
      ),
      latestRebuildEvidence: _latestRebuildEvidence,
      currentReconstructionEpochId:
          currentReconstructionEpochId ?? _currentReconstructionEpochId,
      currentEpochMappings: currentEpochMappings ?? _currentEpochMappings,
      activeReconstructionTaints: _activeReconstructionTaints,
      resolvedReconstructionTaints: _resolvedReconstructionTaints,
    );
  }

  ManualCaptureLedger _copyLedger({
    required ManualCaptureEvent event,
    Map<String, ManualCaptureReconstructionTaint>? activeReconstructionTaints,
  }) {
    return ManualCaptureLedger._(
      jobs: _jobs,
      events: List<ManualCaptureEvent>.unmodifiable(<ManualCaptureEvent>[
        ..._events,
        event,
      ]),
      pendingRebuildDeletedJobIds: _pendingRebuildDeletedJobIds,
      latestRebuildEvidence: _latestRebuildEvidence,
      currentReconstructionEpochId: _currentReconstructionEpochId,
      currentEpochMappings: _currentEpochMappings,
      activeReconstructionTaints:
          activeReconstructionTaints ?? _activeReconstructionTaints,
      resolvedReconstructionTaints: _resolvedReconstructionTaints,
    );
  }

  Set<String> _expectedIds() => _orderedSet(
    _jobs.values
        .where((job) => job.accepted && !job.userDeleted)
        .map((job) => job.captureJobId),
  );

  ManualCaptureClosureReport closureReport({
    required FinalRegistrationObservation finalRegistration,
  }) {
    final expected = <String>{};
    final committed = <String>{};
    final queued = <String>{};
    final ingested = <String>{};
    final mapped = <String>{..._currentEpochMappings.keys};
    final blocking = <String>{
      ..._pendingRebuildDeletedJobIds,
      ..._activeReconstructionTaints.values.map((taint) => taint.captureJobId),
    };

    for (final job in _jobs.values) {
      if (job.userDeleted) continue;
      if (job.stage == ManualCaptureStage.attempted ||
          job.blocked ||
          job.deletionRequested) {
        blocking.add(job.captureJobId);
      }
      if (!job.accepted) continue;
      expected.add(job.captureJobId);
      if (job.photoCommitted) committed.add(job.captureJobId);
      if (job.sfmQueued) queued.add(job.captureJobId);
      if (job.sfmIngested) ingested.add(job.captureJobId);
    }

    final currentMap = currentJobToNativeImageId;
    final finalRegistrationEpochMatches =
        (_currentReconstructionEpochId == null && currentMap.isEmpty) ||
        _currentReconstructionEpochId ==
            finalRegistration.reconstructionEpochId;
    final finalRegistrationMappingMatchesCurrentEpoch = _mapEquals(
      currentMap,
      finalRegistration.jobToNativeImageId,
    );
    final latestRebuildStillDefinesCurrentArtifact =
        _latestRebuildEvidence != null &&
        _latestRebuildEvidence.reconstructionEpochId ==
            _currentReconstructionEpochId &&
        _mapEquals(_latestRebuildEvidence.jobToNativeImageId, currentMap) &&
        _setEquals(_latestRebuildEvidence.activeJobIds, expected);
    final artifactMatchesRebuild =
        !latestRebuildStillDefinesCurrentArtifact ||
        _latestRebuildEvidence.artifactIdentity ==
            finalRegistration.artifactIdentity;

    return ManualCaptureClosureReport._(
      expected: expected,
      committed: committed,
      queued: queued,
      ingested: ingested,
      mapped: mapped,
      registered: finalRegistration.registeredJobIds,
      blockingJobIds: blocking,
      finalRegistration: finalRegistration,
      rebuildRequired: rebuildRequired,
      finalRegistrationArtifactMatchesRebuild: artifactMatchesRebuild,
      finalRegistrationEpochMatches: finalRegistrationEpochMatches,
      finalRegistrationMappingMatchesCurrentEpoch:
          finalRegistrationMappingMatchesCurrentEpoch,
    );
  }

  Map<String, Object?> toJson() {
    final orderedJobs = _jobs.values.toList()
      ..sort((left, right) => left.captureJobId.compareTo(right.captureJobId));
    final activeTaints = _activeReconstructionTaints.values.toList()
      ..sort((left, right) => left.taintId.compareTo(right.taintId));
    final resolvedTaints = _resolvedReconstructionTaints.values.toList()
      ..sort((left, right) => left.taintId.compareTo(right.taintId));
    return <String, Object?>{
      'schema_version': schemaVersion,
      'jobs': orderedJobs.map((job) => job.toJson()).toList(),
      'pending_rebuild_deleted_job_ids': _pendingRebuildDeletedJobIds.toList(),
      'current_reconstruction_epoch_id': _currentReconstructionEpochId,
      'current_job_to_native_image_id': currentJobToNativeImageId,
      'active_reconstruction_taints': activeTaints
          .map((taint) => taint.toJson())
          .toList(),
      'resolved_reconstruction_taints': resolvedTaints
          .map((taint) => taint.toJson())
          .toList(),
      'latest_rebuild_evidence': _latestRebuildEvidence?.toJson(),
    };
  }

  String toCanonicalJson() => _canonicalJson(toJson());
}

final class ManualCaptureClosureReport {
  ManualCaptureClosureReport._({
    required Set<String> expected,
    required Set<String> committed,
    required Set<String> queued,
    required Set<String> ingested,
    required Set<String> mapped,
    required Set<String> registered,
    required Set<String> blockingJobIds,
    required this.finalRegistration,
    required this.rebuildRequired,
    required this.finalRegistrationArtifactMatchesRebuild,
    required this.finalRegistrationEpochMatches,
    required this.finalRegistrationMappingMatchesCurrentEpoch,
  }) : expected = _orderedSet(expected),
       committed = _orderedSet(committed),
       queued = _orderedSet(queued),
       ingested = _orderedSet(ingested),
       mapped = _orderedSet(mapped),
       registered = _orderedSet(registered),
       blockingJobIds = _orderedSet(blockingJobIds),
       missing = Map<String, Set<String>>.unmodifiable(<String, Set<String>>{
         'committed': _difference(expected, committed),
         'queued': _difference(expected, queued),
         'ingested': _difference(expected, ingested),
         'mapped': _difference(expected, mapped),
         'registered': _difference(expected, registered),
       }),
       extra = Map<String, Set<String>>.unmodifiable(<String, Set<String>>{
         'committed': _difference(committed, expected),
         'queued': _difference(queued, expected),
         'ingested': _difference(ingested, expected),
         'mapped': _difference(mapped, expected),
         'registered': _difference(registered, expected),
       });

  final Set<String> expected;
  final Set<String> committed;
  final Set<String> queued;
  final Set<String> ingested;
  final Set<String> mapped;
  final Set<String> registered;
  final Set<String> blockingJobIds;
  final Map<String, Set<String>> missing;
  final Map<String, Set<String>> extra;
  final FinalRegistrationObservation finalRegistration;
  final bool rebuildRequired;
  final bool finalRegistrationArtifactMatchesRebuild;
  final bool finalRegistrationEpochMatches;
  final bool finalRegistrationMappingMatchesCurrentEpoch;

  bool get isComplete =>
      !rebuildRequired &&
      finalRegistrationArtifactMatchesRebuild &&
      finalRegistrationEpochMatches &&
      finalRegistrationMappingMatchesCurrentEpoch &&
      blockingJobIds.isEmpty &&
      missing.values.every((ids) => ids.isEmpty) &&
      extra.values.every((ids) => ids.isEmpty);
}

final class ManualCaptureLedgerViolation extends StateError {
  ManualCaptureLedgerViolation(super.message);
}

String _jobId(String value) => _requireNormalizedToken(value, 'captureJobId');

String _requireNormalizedToken(String value, String name) {
  if (value.isEmpty) {
    throw ArgumentError.value(value, name, 'must not be empty');
  }
  if (value.trim() != value) {
    throw ArgumentError.value(
      value,
      name,
      'must not have leading or trailing whitespace',
    );
  }
  if (value.contains('\u0000') ||
      value.contains('\r') ||
      value.contains('\n')) {
    throw ArgumentError.value(value, name, 'must not contain NUL, CR, or LF');
  }
  return value;
}

String _requireMessage(String value, String name) {
  if (value.isEmpty) {
    throw ArgumentError.value(value, name, 'must not be empty');
  }
  if (value.contains('\u0000')) {
    throw ArgumentError.value(value, name, 'must not contain NUL');
  }
  return value;
}

String _requireResolutionEvidence(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, 'must contain non-whitespace proof');
  }
  if (value.contains('\u0000')) {
    throw ArgumentError.value(value, name, 'must not contain NUL');
  }
  return value;
}

Map<String, String> _validatedJobToNativeImageId(
  Map<String, String> values,
  String name,
) {
  final result = SplayTreeMap<String, String>();
  final nativeImageOwners = <String, String>{};
  for (final entry in values.entries) {
    final jobId = _requireNormalizedToken(entry.key, '$name.jobId');
    final nativeImageId = _requireNormalizedToken(entry.value, '$name[$jobId]');
    final priorOwner = nativeImageOwners[nativeImageId];
    if (priorOwner != null && priorOwner != jobId) {
      throw ArgumentError.value(
        values,
        name,
        'nativeImageId $nativeImageId is shared by $priorOwner and $jobId',
      );
    }
    result[jobId] = nativeImageId;
    nativeImageOwners[nativeImageId] = jobId;
  }
  return Map<String, String>.unmodifiable(result);
}

Set<String> _orderedSet(Iterable<String> values) =>
    Set<String>.unmodifiable(SplayTreeSet<String>.of(values));

Set<String> _difference(Set<String> left, Set<String> right) =>
    _orderedSet(left.difference(right));

bool _setEquals(Set<String> left, Set<String> right) =>
    left.length == right.length && left.containsAll(right);

bool _mapEquals(Map<String, String> left, Map<String, String> right) =>
    left.length == right.length &&
    left.entries.every((entry) => right[entry.key] == entry.value);

String _canonicalJson(Map<String, Object?> value) =>
    jsonEncode(_canonicalize(value));

Object? _canonicalize(Object? value) {
  if (value is Map<String, Object?>) {
    final result = SplayTreeMap<String, Object?>();
    for (final entry in value.entries) {
      result[entry.key] = _canonicalize(entry.value);
    }
    return result;
  }
  if (value is Iterable<Object?>) {
    return value.map(_canonicalize).toList(growable: false);
  }
  return value;
}
