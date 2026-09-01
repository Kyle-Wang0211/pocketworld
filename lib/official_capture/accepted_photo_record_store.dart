import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'accepted_photo_transaction.dart';

enum AcceptedPhotoPublishStatus { published, alreadyPublished, aborted }

class AcceptedPhotoPublishResult {
  const AcceptedPhotoPublishResult(this.status, this.record);

  final AcceptedPhotoPublishStatus status;
  final AcceptedPhotoRecord record;
}

class AcceptedPhotoRecordConflict implements Exception {
  const AcceptedPhotoRecordConflict(this.transactionId);

  final String transactionId;

  @override
  String toString() =>
      'AcceptedPhotoRecordConflict: immutable transaction $transactionId '
      'already has different data';
}

enum AcceptedPhotoProjectionStatus { applied, alreadyApplied, deferred }

class AcceptedPhotoProjectionResult {
  const AcceptedPhotoProjectionResult({
    required this.status,
    required this.transactionId,
    required this.projection,
    this.debt,
  });

  final AcceptedPhotoProjectionStatus status;
  final String transactionId;
  final AcceptedPhotoProjection projection;
  final AcceptedPhotoReplayDebt? debt;
}

class AcceptedPhotoReplayDebt {
  const AcceptedPhotoReplayDebt({
    required this.transactionId,
    required this.projection,
    required this.code,
    required this.message,
    required this.attempts,
    required this.firstFailedAtUtc,
    required this.lastFailedAtUtc,
  });

  final String transactionId;
  final AcceptedPhotoProjection projection;
  final String code;
  final String message;
  final int attempts;
  final DateTime firstFailedAtUtc;
  final DateTime lastFailedAtUtc;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': 1,
    'transactionId': transactionId,
    'projection': projection.name,
    'code': code,
    'message': message,
    'attempts': attempts,
    'firstFailedAtUtc': firstFailedAtUtc.toIso8601String(),
    'lastFailedAtUtc': lastFailedAtUtc.toIso8601String(),
  };

  factory AcceptedPhotoReplayDebt.fromJson(Map<String, Object?> json) {
    final projectionName = json['projection'];
    final projection = AcceptedPhotoProjection.values.where(
      (value) => value.name == projectionName,
    );
    if (projection.length != 1) {
      throw FormatException('unknown accepted-photo projection');
    }
    return AcceptedPhotoReplayDebt(
      transactionId: json['transactionId'] as String,
      projection: projection.single,
      code: json['code'] as String,
      message: json['message'] as String,
      attempts: (json['attempts'] as num).toInt(),
      firstFailedAtUtc: DateTime.parse(json['firstFailedAtUtc'] as String),
      lastFailedAtUtc: DateTime.parse(json['lastFailedAtUtc'] as String),
    );
  }
}

class AcceptedPhotoReplayReport {
  const AcceptedPhotoReplayReport({
    required this.attempted,
    required this.applied,
    required this.remaining,
  });

  final int attempted;
  final int applied;
  final int remaining;
}

/// Process-local read cache of the current durable ledger.
///
/// This registry is deliberately not an admission API. Its contents are
/// replaced or extended only after [AcceptedPhotoRecordStore] has read or
/// atomically published durable record files. UI albums may observe it but may
/// not add or remove membership.
class AcceptedPhotoRecordRegistry {
  AcceptedPhotoRecordRegistry._();

  static String? _scope;
  static final LinkedHashMap<String, AcceptedPhotoRecord> _byTransaction =
      LinkedHashMap<String, AcceptedPhotoRecord>();
  static final Map<String, AcceptedPhotoRecord> _byJpegPath =
      <String, AcceptedPhotoRecord>{};
  static final StreamController<void> _changes =
      StreamController<void>.broadcast();

  static Stream<void> get changes => _changes.stream;
  static String? get scope => _scope;
  static List<AcceptedPhotoRecord> get snapshot =>
      List<AcceptedPhotoRecord>.unmodifiable(_byTransaction.values);

  static AcceptedPhotoRecord? byJpegPath(String path) => _byJpegPath[path];

  static void replaceScope(
    String scope,
    Iterable<AcceptedPhotoRecord> records,
  ) {
    _scope = scope;
    _byTransaction.clear();
    _byJpegPath.clear();
    for (final record in records) {
      _byTransaction[record.transactionId] = record;
      _byJpegPath[record.jpegPath] = record;
    }
    if (!_changes.isClosed) _changes.add(null);
  }

  static void publish(String scope, AcceptedPhotoRecord record) {
    if (_scope != scope) replaceScope(scope, const <AcceptedPhotoRecord>[]);
    final existing = _byTransaction[record.transactionId];
    if (existing == record) return;
    _byTransaction[record.transactionId] = record;
    _byJpegPath[record.jpegPath] = record;
    if (!_changes.isClosed) _changes.add(null);
  }

  static void tombstone(String scope, String transactionId) {
    if (_scope != scope) return;
    final removed = _byTransaction.remove(transactionId);
    if (removed == null) return;
    _byJpegPath.remove(removed.jpegPath);
    if (!_changes.isClosed) _changes.add(null);
  }
}

/// Durable canonical accepted-photo ledger plus projection outbox.
///
/// Record JSON is written to a transaction-unique temporary file, flushed,
/// then renamed inside the same directory. The final record file is immutable
/// and is the sole project-membership truth. Projection receipts and replay
/// debts are separate mutable outbox state and cannot change that truth.
class AcceptedPhotoRecordStore {
  AcceptedPhotoRecordStore._(this.captureDirectory)
    : _ledgerDirectory = Directory(
        '${captureDirectory.path}/accepted_photo_ledger',
      ),
      _recordDirectory = Directory(
        '${captureDirectory.path}/accepted_photo_ledger/records',
      ),
      _debtDirectory = Directory(
        '${captureDirectory.path}/accepted_photo_ledger/debts',
      ),
      _receiptDirectory = Directory(
        '${captureDirectory.path}/accepted_photo_ledger/receipts',
      ),
      _tombstoneDirectory = Directory(
        '${captureDirectory.path}/accepted_photo_ledger/tombstones',
      );

  final Directory captureDirectory;
  final Directory _ledgerDirectory;
  final Directory _recordDirectory;
  final Directory _debtDirectory;
  final Directory _receiptDirectory;
  final Directory _tombstoneDirectory;
  final LinkedHashMap<String, AcceptedPhotoRecord> _records =
      LinkedHashMap<String, AcceptedPhotoRecord>();
  final Map<String, AcceptedPhotoReplayDebt> _debts =
      <String, AcceptedPhotoReplayDebt>{};
  final Set<String> _tombstones = <String>{};
  final Map<String, Future<AcceptedPhotoProjectionResult>>
  _inFlightProjections = <String, Future<AcceptedPhotoProjectionResult>>{};
  Future<void> _mutationBarrier = Future<void>.value();
  int _temporarySequence = 0;

  static Future<AcceptedPhotoRecordStore> open(
    Directory captureDirectory,
  ) async {
    final store = AcceptedPhotoRecordStore._(captureDirectory.absolute);
    await store._ledgerDirectory.create(recursive: true);
    await store._recordDirectory.create(recursive: true);
    await store._debtDirectory.create(recursive: true);
    await store._receiptDirectory.create(recursive: true);
    await store._tombstoneDirectory.create(recursive: true);
    await store._load();
    AcceptedPhotoRecordRegistry.replaceScope(
      store.captureDirectory.path,
      store.snapshot,
    );
    return store;
  }

  List<AcceptedPhotoRecord> get snapshot =>
      List<AcceptedPhotoRecord>.unmodifiable(_records.values);

  List<AcceptedPhotoReplayDebt> get debtSnapshot {
    final debts = _debts.values.toList(growable: false)
      ..sort((left, right) {
        final byTransaction = left.transactionId.compareTo(right.transactionId);
        return byTransaction != 0
            ? byTransaction
            : left.projection.index.compareTo(right.projection.index);
      });
    return List<AcceptedPhotoReplayDebt>.unmodifiable(debts);
  }

  AcceptedPhotoRecord? recordForTransaction(String transactionId) =>
      _records[transactionId];

  String recordPath(String transactionId) =>
      '${_recordDirectory.path}/${_fileKey(transactionId)}.json';

  String tombstonePath(String transactionId) =>
      '${_tombstoneDirectory.path}/${_fileKey(transactionId)}.json';

  Future<AcceptedPhotoPublishResult> publish(
    AcceptedPhotoRecord record, {
    required bool Function() canPublish,
  }) => _serialized(() async {
    if (_tombstones.contains(record.transactionId) ||
        await File(tombstonePath(record.transactionId)).exists()) {
      return AcceptedPhotoPublishResult(
        AcceptedPhotoPublishStatus.aborted,
        record,
      );
    }
    await _validateRecord(record);
    final existing = _records[record.transactionId];
    if (existing != null) {
      if (existing != record) {
        throw AcceptedPhotoRecordConflict(record.transactionId);
      }
      return AcceptedPhotoPublishResult(
        AcceptedPhotoPublishStatus.alreadyPublished,
        existing,
      );
    }

    final destination = File(recordPath(record.transactionId));
    if (await destination.exists()) {
      final diskRecord = await _readRecord(destination);
      if (diskRecord != record) {
        throw AcceptedPhotoRecordConflict(record.transactionId);
      }
      _records[record.transactionId] = diskRecord;
      AcceptedPhotoRecordRegistry.publish(captureDirectory.path, diskRecord);
      return AcceptedPhotoPublishResult(
        AcceptedPhotoPublishStatus.alreadyPublished,
        diskRecord,
      );
    }

    final temporary = _temporaryFile(destination);
    try {
      await temporary.writeAsString(record.canonicalJson, flush: true);
      if (!canPublish()) {
        await _deleteIfPresent(temporary);
        return AcceptedPhotoPublishResult(
          AcceptedPhotoPublishStatus.aborted,
          record,
        );
      }
      // There is deliberately no await between the final generation check
      // above and submission of the same-directory rename below.
      await temporary.rename(destination.path);
    } catch (_) {
      await _deleteIfPresent(temporary);
      rethrow;
    }

    _records[record.transactionId] = record;
    _sortRecords();
    AcceptedPhotoRecordRegistry.publish(captureDirectory.path, record);
    return AcceptedPhotoPublishResult(
      AcceptedPhotoPublishStatus.published,
      record,
    );
  });

  /// Durably removes canonical membership. The tombstone is flushed and
  /// atomically renamed before the record, receipts, debts, registry, or JPEG
  /// projections can be removed, so a crash can never resurrect membership.
  Future<bool> tombstone(String transactionId) => _serialized(() async {
    if (_tombstones.contains(transactionId)) return false;
    final record = _records[transactionId];
    if (record == null) return false;
    final destination = File(tombstonePath(transactionId));
    await _atomicWriteJson(destination, <String, Object?>{
      'schemaVersion': 1,
      'transactionId': transactionId,
      'deletedAtUtc': DateTime.now().toUtc().toIso8601String(),
    });
    _tombstones.add(transactionId);
    _records.remove(transactionId);
    _debts.removeWhere((key, _) => key.startsWith('$transactionId:'));
    AcceptedPhotoRecordRegistry.tombstone(captureDirectory.path, transactionId);
    await _deleteIfPresent(File(recordPath(transactionId)));
    await _deleteProjectionState(transactionId);
    return true;
  });

  Future<AcceptedPhotoProjectionResult> project({
    required String transactionId,
    required AcceptedPhotoProjection projection,
    required AcceptedPhotoProjectionHandler apply,
  }) {
    final key = _projectionKey(transactionId, projection);
    final existing = _inFlightProjections[key];
    if (existing != null) return existing;
    final future = _projectOnce(
      transactionId: transactionId,
      projection: projection,
      apply: apply,
    );
    _inFlightProjections[key] = future;
    future.whenComplete(() => _inFlightProjections.remove(key));
    return future;
  }

  Future<AcceptedPhotoProjectionResult> _projectOnce({
    required String transactionId,
    required AcceptedPhotoProjection projection,
    required AcceptedPhotoProjectionHandler apply,
  }) async {
    final record = _records[transactionId];
    if (record == null) {
      throw StateError('No canonical record for $transactionId');
    }
    if (await isProjectionComplete(transactionId, projection)) {
      return AcceptedPhotoProjectionResult(
        status: AcceptedPhotoProjectionStatus.alreadyApplied,
        transactionId: transactionId,
        projection: projection,
      );
    }

    try {
      await apply(record);
    } catch (error) {
      final typed = error is AcceptedPhotoProjectionException
          ? error
          : AcceptedPhotoProjectionException(
              code: 'projection_failed',
              message: '$error',
            );
      final debt = await _recordDebt(
        transactionId: transactionId,
        projection: projection,
        error: typed,
      );
      return AcceptedPhotoProjectionResult(
        status: AcceptedPhotoProjectionStatus.deferred,
        transactionId: transactionId,
        projection: projection,
        debt: debt,
      );
    }

    await _serialized(() async {
      final receipt = _receiptFile(transactionId, projection);
      if (!await receipt.exists()) {
        await _atomicWriteJson(receipt, <String, Object?>{
          'schemaVersion': 1,
          'transactionId': transactionId,
          'projection': projection.name,
          'completedAtUtc': DateTime.now().toUtc().toIso8601String(),
        });
      }
      _debts.remove(_projectionKey(transactionId, projection));
      await _deleteIfPresent(_debtFile(transactionId, projection));
    });
    return AcceptedPhotoProjectionResult(
      status: AcceptedPhotoProjectionStatus.applied,
      transactionId: transactionId,
      projection: projection,
    );
  }

  Future<bool> isProjectionComplete(
    String transactionId,
    AcceptedPhotoProjection projection,
  ) => _receiptFile(transactionId, projection).exists();

  Future<AcceptedPhotoReplayReport> replay({
    required Map<AcceptedPhotoProjection, AcceptedPhotoProjectionHandler>
    handlers,
  }) async {
    var attempted = 0;
    var applied = 0;
    for (final debt in debtSnapshot) {
      final handler = handlers[debt.projection];
      if (handler == null) continue;
      attempted++;
      final result = await project(
        transactionId: debt.transactionId,
        projection: debt.projection,
        apply: handler,
      );
      if (result.status == AcceptedPhotoProjectionStatus.applied ||
          result.status == AcceptedPhotoProjectionStatus.alreadyApplied) {
        applied++;
      }
    }
    return AcceptedPhotoReplayReport(
      attempted: attempted,
      applied: applied,
      remaining: debtSnapshot.length,
    );
  }

  Future<AcceptedPhotoReplayDebt> _recordDebt({
    required String transactionId,
    required AcceptedPhotoProjection projection,
    required AcceptedPhotoProjectionException error,
  }) => _serialized(() async {
    final key = _projectionKey(transactionId, projection);
    final previous = _debts[key];
    final now = DateTime.now().toUtc();
    final debt = AcceptedPhotoReplayDebt(
      transactionId: transactionId,
      projection: projection,
      code: error.code,
      message: error.message,
      attempts: (previous?.attempts ?? 0) + 1,
      firstFailedAtUtc: previous?.firstFailedAtUtc ?? now,
      lastFailedAtUtc: now,
    );
    await _atomicWriteJson(_debtFile(transactionId, projection), debt.toJson());
    _debts[key] = debt;
    return debt;
  });

  Future<void> _load() async {
    final tombstoneFiles = await _jsonFiles(_tombstoneDirectory);
    for (final file in tombstoneFiles) {
      final decoded = await _readJsonObject(file);
      final transactionId = decoded['transactionId'];
      if (transactionId is! String || transactionId.isEmpty) {
        throw const FormatException('invalid accepted-photo tombstone');
      }
      _tombstones.add(transactionId);
    }

    final recordFiles = await _jsonFiles(_recordDirectory);
    for (final file in recordFiles) {
      final record = await _readRecord(file);
      if (_tombstones.contains(record.transactionId)) {
        await _deleteIfPresent(file);
        continue;
      }
      final existing = _records[record.transactionId];
      if (existing != null && existing != record) {
        throw AcceptedPhotoRecordConflict(record.transactionId);
      }
      await _validateRecord(record);
      _records[record.transactionId] = record;
    }
    _sortRecords();

    final debtFiles = await _jsonFiles(_debtDirectory);
    for (final file in debtFiles) {
      final decoded = await _readJsonObject(file);
      final debt = AcceptedPhotoReplayDebt.fromJson(decoded);
      if (!_records.containsKey(debt.transactionId)) continue;
      if (await isProjectionComplete(debt.transactionId, debt.projection)) {
        await _deleteIfPresent(file);
        continue;
      }
      _debts[_projectionKey(debt.transactionId, debt.projection)] = debt;
    }
  }

  Future<void> _validateRecord(AcceptedPhotoRecord record) async {
    if (record.schemaVersion != AcceptedPhotoRecord.currentSchemaVersion ||
        record.transactionId.isEmpty ||
        record.generation <= 0 ||
        record.frameId.isEmpty ||
        record.imageWidth != 4032 ||
        record.imageHeight != 3024 ||
        !record.triggerTimestamp.isFinite ||
        !record.captureTimestamp.isFinite ||
        record.requestPose.length != 16 ||
        record.requestPose.any((value) => !value.isFinite) ||
        record.evidencePose.length != 16 ||
        record.evidencePose.any((value) => !value.isFinite) ||
        record.cardPose.length != 16 ||
        record.cardPose.any((value) => !value.isFinite) ||
        record.intrinsics.length < 4 ||
        record.intrinsics
            .take(4)
            .any((value) => !value.isFinite || value <= 0)) {
      throw const FormatException('invalid canonical accepted-photo record');
    }
    final lowerPath = record.jpegPath.toLowerCase();
    if (!lowerPath.endsWith('.jpg') && !lowerPath.endsWith('.jpeg')) {
      throw const FormatException('canonical photo must be a JPEG');
    }
    final file = File(record.jpegPath);
    if (!await file.exists() || await file.length() <= 0) {
      throw const FormatException('canonical JPEG is missing or empty');
    }
    final root = await captureDirectory.resolveSymbolicLinks();
    final canonicalJpeg = await file.resolveSymbolicLinks();
    final rootPrefix = root.endsWith(Platform.pathSeparator)
        ? root
        : '$root${Platform.pathSeparator}';
    if (!canonicalJpeg.startsWith(rootPrefix)) {
      throw const FormatException('canonical JPEG escapes capture directory');
    }
    final gray = record.gray128Base64;
    if (gray != null && base64Decode(gray).length != 128 * 128) {
      throw const FormatException('gray128 evidence has the wrong size');
    }
  }

  Future<AcceptedPhotoRecord> _readRecord(File file) async =>
      AcceptedPhotoRecord.fromJson(await _readJsonObject(file));

  static Future<Map<String, Object?>> _readJsonObject(File file) async {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) throw const FormatException('expected JSON object');
    return decoded.map((key, value) => MapEntry('$key', value));
  }

  Future<void> _atomicWriteJson(
    File destination,
    Map<String, Object?> value,
  ) async {
    final temporary = _temporaryFile(destination);
    try {
      await temporary.writeAsString(jsonEncode(value), flush: true);
      await temporary.rename(destination.path);
    } catch (_) {
      await _deleteIfPresent(temporary);
      rethrow;
    }
  }

  File _temporaryFile(File destination) {
    _temporarySequence++;
    return File(
      '${destination.path}.${DateTime.now().microsecondsSinceEpoch}.'
      '$_temporarySequence.tmp',
    );
  }

  File _debtFile(String transactionId, AcceptedPhotoProjection projection) =>
      File(
        '${_debtDirectory.path}/${_fileKey(transactionId)}.'
        '${projection.name}.json',
      );

  File _receiptFile(String transactionId, AcceptedPhotoProjection projection) =>
      File(
        '${_receiptDirectory.path}/${_fileKey(transactionId)}.'
        '${projection.name}.json',
      );

  Future<void> _deleteProjectionState(String transactionId) async {
    final prefix = '${_fileKey(transactionId)}.';
    for (final directory in <Directory>[_debtDirectory, _receiptDirectory]) {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is File && entity.uri.pathSegments.last.startsWith(prefix)) {
          await _deleteIfPresent(entity);
        }
      }
    }
  }

  Future<T> _serialized<T>(Future<T> Function() operation) async {
    final previous = _mutationBarrier;
    final release = Completer<void>();
    _mutationBarrier = release.future;
    await previous;
    try {
      return await operation();
    } finally {
      release.complete();
    }
  }

  void _sortRecords() {
    final sorted = _records.values.toList(growable: false)
      ..sort((left, right) {
        final timestamp = left.captureTimestamp.compareTo(
          right.captureTimestamp,
        );
        return timestamp != 0
            ? timestamp
            : left.transactionId.compareTo(right.transactionId);
      });
    _records
      ..clear()
      ..addEntries(
        sorted.map((record) => MapEntry(record.transactionId, record)),
      );
  }

  static Future<List<File>> _jsonFiles(Directory directory) async {
    final files = <File>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith('.json')) files.add(entity);
    }
    files.sort((left, right) => left.path.compareTo(right.path));
    return files;
  }

  static Future<void> _deleteIfPresent(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Best-effort cleanup. A final record/receipt is never deleted here.
    }
  }

  static String _projectionKey(
    String transactionId,
    AcceptedPhotoProjection projection,
  ) => '$transactionId:${projection.name}';

  static String _fileKey(String value) =>
      base64Url.encode(utf8.encode(value)).replaceAll('=', '');
}
