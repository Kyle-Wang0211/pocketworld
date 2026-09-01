import 'dart:async';

import 'package:flutter/foundation.dart';

import 'auto_capture_controller.dart';

@immutable
class ManualCaptureTicket {
  const ManualCaptureTicket({
    required this.id,
    required this.tapTimestampMicros,
    this.automaticSelection = false,
    this.automaticStillTicket,
  });

  final int id;
  final int tapTimestampMicros;
  final bool automaticSelection;
  final AutomaticStillTicket? automaticStillTicket;
}

typedef ManualCaptureExecutor =
    Future<void> Function(ManualCaptureTicket ticket);
typedef ManualCaptureErrorHandler =
    void Function(
      ManualCaptureTicket ticket,
      Object error,
      StackTrace stackTrace,
    );

/// A single-flight shutter receipt latch.
///
/// Admission activates one ticket and invokes its executor immediately. While
/// that receipt is unresolved, later admissions are rejected rather than
/// retained for a camera pose that may already be stale.
class ManualCaptureQueue extends ChangeNotifier {
  ManualCaptureQueue({
    required ManualCaptureExecutor execute,
    required int maxTickets,
    int Function()? nowMicros,
    ManualCaptureErrorHandler? onError,
  }) : _execute = execute,
       _maxTickets = maxTickets,
       _nowMicros = nowMicros ?? _systemNowMicros,
       _onError = onError {
    if (maxTickets <= 0) {
      throw ArgumentError.value(maxTickets, 'maxTickets', 'must be positive');
    }
  }

  final ManualCaptureExecutor _execute;
  final int _maxTickets;
  final int Function() _nowMicros;
  final ManualCaptureErrorHandler? _onError;

  ManualCaptureTicket? _active;
  Completer<void>? _drainCompleter;
  var _accepting = true;
  var _disposed = false;
  var _notificationScheduled = false;
  var _nextId = 1;

  /// Retained for callers that expose queue diagnostics. A single-flight
  /// capture never owns a pending ticket: an accepted ticket becomes active
  /// before [enqueue] returns, and a busy admission is rejected.
  int get pendingCount => 0;

  int get inFlightCount => _active == null ? 0 : 1;

  int get outstandingCount => pendingCount + inFlightCount;

  bool get accepting => _accepting && !_disposed;

  bool canEnqueue({required int verifiedCount}) {
    _validateVerifiedCount(verifiedCount);
    return accepting &&
        _active == null &&
        verifiedCount + outstandingCount < _maxTickets;
  }

  ManualCaptureTicket? enqueue({
    required int verifiedCount,
    bool automaticSelection = false,
    AutomaticStillTicket? automaticStillTicket,
  }) {
    if (automaticSelection != (automaticStillTicket != null)) {
      throw ArgumentError(
        'automaticSelection and automaticStillTicket must be supplied together',
      );
    }
    if (!canEnqueue(verifiedCount: verifiedCount)) return null;

    final ticket = ManualCaptureTicket(
      id: _nextId,
      tapTimestampMicros: _nowMicros(),
      automaticSelection: automaticSelection,
      automaticStillTicket: automaticStillTicket,
    );
    _nextId += 1;
    _active = ticket;
    _scheduleNotification();

    // Invoke directly rather than through a microtask. This makes admission
    // and the executor's synchronous prefix one transaction: a second shutter
    // in this Dart turn observes [_active] and cannot become stale backlog.
    try {
      final execution = _execute(ticket);
      unawaited(_awaitExecution(ticket, execution));
    } catch (error, stackTrace) {
      _finishExecution(ticket, error: error, stackTrace: stackTrace);
    }
    return ticket;
  }

  Future<void> freezeAndDrain() {
    if (!_disposed && _accepting) {
      _accepting = false;
      _scheduleNotification();
    }
    if (outstandingCount == 0) return Future<void>.value();
    return (_drainCompleter ??= Completer<void>()).future;
  }

  void resume() {
    if (_disposed) return;
    if (_accepting) return;
    if (_active != null) {
      throw StateError('Cannot resume before the current drain completes.');
    }
    _accepting = true;
    _scheduleNotification();
  }

  void cancelPending() {
    if (_disposed) return;
    final changed = _accepting;
    _accepting = false;
    if (changed) _scheduleNotification();
    _completeDrainIfIdle();
  }

  Future<void> _awaitExecution(
    ManualCaptureTicket ticket,
    Future<void> execution,
  ) async {
    try {
      await execution;
      _finishExecution(ticket);
    } catch (error, stackTrace) {
      _finishExecution(ticket, error: error, stackTrace: stackTrace);
    }
  }

  void _finishExecution(
    ManualCaptureTicket ticket, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (!identical(_active, ticket)) return;
    if (error != null && !_disposed) {
      _reportExecutorError(ticket, error, stackTrace ?? StackTrace.current);
    }
    _active = null;
    _scheduleNotification();
    _completeDrainIfIdle();
  }

  void _scheduleNotification() {
    if (_disposed || _notificationScheduled) return;
    _notificationScheduled = true;
    scheduleMicrotask(() {
      _notificationScheduled = false;
      if (_disposed) return;
      notifyListeners();
    });
  }

  void _completeDrainIfIdle() {
    if (outstandingCount != 0) return;
    final completer = _drainCompleter;
    _drainCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  void _reportExecutorError(
    ManualCaptureTicket ticket,
    Object error,
    StackTrace stackTrace,
  ) {
    final handler = _onError;
    if (handler != null) {
      try {
        handler(ticket, error, stackTrace);
        return;
      } catch (handlerError, handlerStackTrace) {
        _reportFrameworkError(
          FlutterErrorDetails(
            exception: handlerError,
            stack: handlerStackTrace,
            library: 'manual capture queue',
            context: ErrorDescription(
              'while reporting failure for ticket ${ticket.id}',
            ),
          ),
        );
        return;
      }
    }
    _reportFrameworkError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'manual capture queue',
        context: ErrorDescription('while executing ticket ${ticket.id}'),
      ),
    );
  }

  void _reportFrameworkError(FlutterErrorDetails details) {
    try {
      FlutterError.reportError(details);
    } catch (_) {
      // A framework reporter must not prevent later tickets from executing.
    }
  }

  void _validateVerifiedCount(int verifiedCount) {
    if (verifiedCount < 0) {
      throw ArgumentError.value(
        verifiedCount,
        'verifiedCount',
        'must not be negative',
      );
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _accepting = false;
    _completeDrainIfIdle();
    super.dispose();
  }

  static int _systemNowMicros() => DateTime.now().microsecondsSinceEpoch;
}
