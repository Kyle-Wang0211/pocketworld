import 'dart:async';

/// Deterministic, platform-independent lifecycle state for live SfM delivery.
///
/// Native sessions and isolates stay in [sfm_live_recon.dart]; this module owns
/// the invariants that must remain testable without loading a device FFI slice.
enum SfmDeliveryStatus { queued, inFlight, accepted, removing, removed, failed }

class SfmDeliveryFailure {
  const SfmDeliveryFailure({
    required this.seq,
    required this.jpegPath,
    required this.result,
  });

  final int seq;
  final String jpegPath;
  final String result;
}

class _SfmDeliveryRecord {
  _SfmDeliveryRecord({required this.jpegPath});

  final String jpegPath;
  SfmDeliveryStatus status = SfmDeliveryStatus.queued;
  String? failureResult;
}

/// One record per user-offered JPEG. Retries keep the original [seq], so
/// [offeredCount] is a photo count rather than an attempt count.
class SfmDeliveryLedger {
  SfmDeliveryLedger({this.maxInFlight = 2})
    : assert(maxInFlight > 0, 'maxInFlight must be positive');

  final int maxInFlight;
  final Map<int, _SfmDeliveryRecord> _records = <int, _SfmDeliveryRecord>{};
  int _inFlightCount = 0;

  int get offeredCount => _records.length;
  int get inFlightCount => _inFlightCount;

  Iterable<int> get queuedSeqs sync* {
    for (final entry in _records.entries) {
      if (entry.value.status == SfmDeliveryStatus.queued) yield entry.key;
    }
  }

  List<SfmDeliveryFailure> get failures => <SfmDeliveryFailure>[
    for (final entry in _records.entries)
      if (entry.value.status == SfmDeliveryStatus.failed)
        SfmDeliveryFailure(
          seq: entry.key,
          jpegPath: entry.value.jpegPath,
          result: entry.value.failureResult ?? 'unknown',
        ),
  ];

  bool get hasOutstanding => _records.values.any(
    (record) =>
        record.status == SfmDeliveryStatus.queued ||
        record.status == SfmDeliveryStatus.inFlight ||
        record.status == SfmDeliveryStatus.removing,
  );

  bool get hasPendingRemoval => _records.values.any(
    (record) => record.status == SfmDeliveryStatus.removing,
  );

  int get pendingRemovalCount => _records.values
      .where((record) => record.status == SfmDeliveryStatus.removing)
      .length;

  bool get canFinalize => _records.values.every(
    (record) =>
        record.status == SfmDeliveryStatus.accepted ||
        record.status == SfmDeliveryStatus.removed,
  );

  void offer({required int seq, required String jpegPath}) {
    if (_records.containsKey(seq)) {
      throw StateError('SfM offer sequence $seq already exists');
    }
    _records[seq] = _SfmDeliveryRecord(jpegPath: jpegPath);
  }

  /// Atomically owns one worker slot. Call this before any asynchronous file
  /// check or SendPort dispatch so a re-entrant offer cannot overbook capacity.
  bool reserve(int seq) {
    final record = _required(seq);
    if (record.status != SfmDeliveryStatus.queued ||
        _inFlightCount >= maxInFlight) {
      return false;
    }
    record.status = SfmDeliveryStatus.inFlight;
    _inFlightCount++;
    return true;
  }

  void acknowledgeSuccess(int seq) {
    final record = _requiredInFlight(seq);
    _releaseSlot(record);
    record.status = SfmDeliveryStatus.accepted;
    record.failureResult = null;
  }

  void acknowledgeFailure(int seq, {required String result}) {
    final record = _requiredInFlight(seq);
    _releaseSlot(record);
    record.status = SfmDeliveryStatus.failed;
    record.failureResult = result;
  }

  void fail(int seq, {required String result}) {
    final record = _required(seq);
    if (record.status == SfmDeliveryStatus.inFlight) {
      _releaseSlot(record);
    } else if (record.status != SfmDeliveryStatus.queued) {
      throw StateError('SfM offer $seq cannot fail from ${record.status}');
    }
    record.status = SfmDeliveryStatus.failed;
    record.failureResult = result;
  }

  /// Releases the current attempt while retaining the same offer identity.
  void retry(int seq) {
    final record = _requiredInFlight(seq);
    _releaseSlot(record);
    record.status = SfmDeliveryStatus.queued;
    record.failureResult = null;
  }

  void beginRemoval(int seq) {
    final record = _required(seq);
    if (record.status == SfmDeliveryStatus.inFlight) {
      _releaseSlot(record);
    } else if (record.status != SfmDeliveryStatus.accepted) {
      throw StateError(
        'SfM offer $seq cannot begin removal from ${record.status}',
      );
    }
    record.status = SfmDeliveryStatus.removing;
    record.failureResult = null;
  }

  void completeRemoval(
    int seq, {
    required bool removed,
    String result = 'removeFailed',
  }) {
    final record = _required(seq);
    if (record.status != SfmDeliveryStatus.removing) {
      throw StateError(
        'SfM offer $seq cannot complete removal from ${record.status}',
      );
    }
    record.status = removed
        ? SfmDeliveryStatus.removed
        : SfmDeliveryStatus.failed;
    record.failureResult = removed ? null : result;
  }

  void remove(int seq) {
    final record = _required(seq);
    if (record.status == SfmDeliveryStatus.inFlight) {
      _releaseSlot(record);
    }
    record.status = SfmDeliveryStatus.removed;
    record.failureResult = null;
  }

  void failOutstanding({required String result}) {
    for (final record in _records.values) {
      if (record.status == SfmDeliveryStatus.inFlight) {
        _releaseSlot(record);
        record.status = SfmDeliveryStatus.failed;
        record.failureResult = result;
      } else if (record.status == SfmDeliveryStatus.queued) {
        record.status = SfmDeliveryStatus.failed;
        record.failureResult = result;
      } else if (record.status == SfmDeliveryStatus.removing) {
        record.status = SfmDeliveryStatus.failed;
        record.failureResult = result;
      }
    }
  }

  _SfmDeliveryRecord _required(int seq) {
    final record = _records[seq];
    if (record == null) throw StateError('Unknown SfM offer sequence $seq');
    return record;
  }

  _SfmDeliveryRecord _requiredInFlight(int seq) {
    final record = _required(seq);
    if (record.status != SfmDeliveryStatus.inFlight) {
      throw StateError('SfM offer $seq is ${record.status}, not in flight');
    }
    return record;
  }

  void _releaseSlot(_SfmDeliveryRecord record) {
    if (record.status != SfmDeliveryStatus.inFlight || _inFlightCount <= 0) {
      throw StateError('SfM worker-slot accounting underflow');
    }
    _inFlightCount--;
  }
}

enum SfmTerminalFailureKind {
  startupFailed,
  workerFatal,
  workerExited,
  deliveryFailed,
  finalizeTimeout,
  workerProtocol,
  disposed,
}

class SfmTerminalFailure {
  const SfmTerminalFailure({
    required this.kind,
    required this.stage,
    required this.message,
  });

  final SfmTerminalFailureKind kind;
  final String stage;
  final String message;
}

/// Accepts the first terminal failure only. VM error and exit notifications can
/// race; callers must never surface two terminal outcomes for one worker.
class SfmTerminalGate {
  SfmTerminalFailure? _failure;

  SfmTerminalFailure? get failure => _failure;

  SfmTerminalFailure? fail({
    required SfmTerminalFailureKind kind,
    required String stage,
    required String message,
  }) {
    if (_failure != null) return null;
    return _failure = SfmTerminalFailure(
      kind: kind,
      stage: stage,
      message: message,
    );
  }
}

/// Process environment mutations are global, so every terminal path must
/// restore the value observed before this reconstruction session started.
class SfmScopedEnvironmentOverride {
  SfmScopedEnvironmentOverride({
    required this.initialValue,
    required this.setValue,
    required this.unsetValue,
    this.onRestore,
  });

  final String? initialValue;
  final void Function(String value) setValue;
  final void Function() unsetValue;
  final void Function()? onRestore;
  bool _enabled = false;
  bool _restored = false;

  bool get isEnabled => _enabled && !_restored;

  void enable(String value) {
    if (_restored) throw StateError('Environment override already restored');
    setValue(value);
    _enabled = true;
  }

  void restore() {
    if (_restored || !_enabled) return;
    _restored = true;
    if (initialValue == null) {
      unsetValue();
    } else {
      setValue(initialValue!);
    }
    onRestore?.call();
  }
}

/// Leading-edge publication with a single latest trailing value per interval.
/// It bounds downstream snapshot conversion without changing reconstruction.
class SfmLatestWinsPublisher<T> {
  SfmLatestWinsPublisher({required this.interval, required this.publish});

  final Duration interval;
  final void Function(T value) publish;
  Timer? _timer;
  T? _pending;
  bool _hasPending = false;
  bool _disposed = false;

  void add(T value) {
    if (_disposed) return;
    if (_timer == null) {
      publish(value);
      _arm();
      return;
    }
    _pending = value;
    _hasPending = true;
  }

  void _arm() {
    _timer = Timer(interval, () {
      _timer = null;
      if (_disposed || !_hasPending) return;
      final next = _pending as T;
      _pending = null;
      _hasPending = false;
      publish(next);
      _arm();
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _pending = null;
    _hasPending = false;
  }
}
