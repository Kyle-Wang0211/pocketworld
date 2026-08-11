import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

@immutable
class ManualCaptureTicket {
  const ManualCaptureTicket({
    required this.id,
    required this.tapTimestampMicros,
  });

  final int id;
  final int tapTimestampMicros;
}

typedef ManualCaptureExecutor =
    Future<void> Function(ManualCaptureTicket ticket);
typedef ManualCaptureErrorHandler =
    void Function(
      ManualCaptureTicket ticket,
      Object error,
      StackTrace stackTrace,
    );

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
  final Queue<ManualCaptureTicket> _pending = Queue<ManualCaptureTicket>();

  ManualCaptureTicket? _active;
  Completer<void>? _drainCompleter;
  var _accepting = true;
  var _disposed = false;
  var _notificationScheduled = false;
  var _pumpScheduled = false;
  var _pumping = false;
  var _nextId = 1;

  int get pendingCount => _pending.length;

  int get inFlightCount => _active == null ? 0 : 1;

  int get outstandingCount => pendingCount + inFlightCount;

  bool get accepting => _accepting && !_disposed;

  bool canEnqueue({required int verifiedCount}) {
    _validateVerifiedCount(verifiedCount);
    return accepting && verifiedCount + outstandingCount < _maxTickets;
  }

  ManualCaptureTicket? enqueue({required int verifiedCount}) {
    if (!canEnqueue(verifiedCount: verifiedCount)) return null;

    final ticket = ManualCaptureTicket(
      id: _nextId,
      tapTimestampMicros: _nowMicros(),
    );
    _nextId += 1;
    _pending.addLast(ticket);
    _schedulePump();
    _scheduleNotification();
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
    final drainCompleter = _drainCompleter;
    if (drainCompleter != null && !drainCompleter.isCompleted) {
      throw StateError('Cannot resume before the current drain completes.');
    }
    _accepting = true;
    _scheduleNotification();
  }

  void cancelPending() {
    if (_disposed) return;
    final changed = _accepting || _pending.isNotEmpty;
    _accepting = false;
    _pending.clear();
    if (changed) _scheduleNotification();
    _completeDrainIfIdle();
  }

  Future<void> _pump() async {
    if (_disposed || _pumping) return;
    _pumping = true;
    try {
      while (!_disposed && _pending.isNotEmpty) {
        final ticket = _pending.removeFirst();
        _active = ticket;
        _scheduleNotification();
        try {
          await _execute(ticket);
        } catch (error, stackTrace) {
          if (!_disposed) {
            _reportExecutorError(ticket, error, stackTrace);
          }
        } finally {
          _active = null;
          _scheduleNotification();
          _completeDrainIfIdle();
        }
      }
    } finally {
      _pumping = false;
      _completeDrainIfIdle();
      if (!_disposed && _pending.isNotEmpty) _schedulePump();
    }
  }

  void _schedulePump() {
    if (_disposed || _pumping || _pumpScheduled) return;
    _pumpScheduled = true;
    scheduleMicrotask(() {
      _pumpScheduled = false;
      if (_disposed || _pumping || _pending.isEmpty) {
        _completeDrainIfIdle();
        return;
      }
      unawaited(_pump());
    });
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
    _pending.clear();
    _completeDrainIfIdle();
    super.dispose();
  }

  static int _systemNowMicros() => DateTime.now().microsecondsSinceEpoch;
}
