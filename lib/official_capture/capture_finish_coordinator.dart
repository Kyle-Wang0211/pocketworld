import 'dart:async';

/// The monotonic lifecycle of one capture route.
///
/// A coordinator instance owns one capture only. Create a new instance for a
/// new route instead of resetting an exited instance.
enum CaptureFinishPhase {
  capturing,
  committing,
  drainingActiveTicket,
  cameraStopped,
  processing,
  success,
  error,
  cancelled,
  exiting,
  exited,
}

/// Navigation requested at the synchronous Finish commit boundary.
enum CaptureFinishExitIntent { remainOnRoute, popToDrafts, discardCapture }

/// The immutable result of a finish attempt.
enum CaptureFinishTerminalOutcome { success, error, cancelled }

/// Generation token required by every asynchronous continuation.
///
/// The constructor is public so adapters can deserialize or deliberately
/// reject stale tokens without retaining coordinator internals.
final class CaptureFinishAttempt {
  const CaptureFinishAttempt(this.generation);

  final int generation;

  @override
  bool operator ==(Object other) =>
      other is CaptureFinishAttempt && other.generation == generation;

  @override
  int get hashCode => generation.hashCode;

  @override
  String toString() => 'CaptureFinishAttempt($generation)';
}

/// Evidence retained for the first error terminal.
final class CaptureFinishFailure {
  const CaptureFinishFailure({
    required this.stage,
    required this.error,
    required this.stackTrace,
    required this.timedOut,
  });

  final String stage;
  final Object error;
  final StackTrace stackTrace;
  final bool timedOut;
}

/// Typed timeout used when an owned await does not reach a terminal result.
final class CaptureFinishStageTimeout extends TimeoutException {
  CaptureFinishStageTimeout(this.stage, Duration duration)
    : super('$stage did not finish before its deadline', duration);

  final String stage;
}

typedef CaptureFinishStateListener = void Function(CaptureFinishPhase phase);

/// Pure-Dart owner of capture Finish state and its exactly-once terminal.
///
/// Native, Flutter, reconstruction, colorization, and persistence adapters
/// remain outside this class. They hand their asynchronous work to
/// [orchestrateToProcessing] or [runProcessingStep], then report the one final
/// result through [completeSuccess] or [completeError].
final class CaptureFinishCoordinator {
  CaptureFinishCoordinator({required this.stageTimeout, this.onStateChanged}) {
    if (stageTimeout.inMicroseconds <= 0) {
      throw ArgumentError.value(
        stageTimeout,
        'stageTimeout',
        'must be greater than zero',
      );
    }
  }

  final Duration stageTimeout;
  final CaptureFinishStateListener? onStateChanged;

  CaptureFinishPhase _phase = CaptureFinishPhase.capturing;
  int _generation = 0;
  CaptureFinishExitIntent? _exitIntent;
  CaptureFinishTerminalOutcome? _terminalOutcome;
  CaptureFinishFailure? _failure;
  final List<CaptureFinishFailure> _cleanupFailures = <CaptureFinishFailure>[];

  CaptureFinishPhase get phase => _phase;
  int get currentGeneration => _generation;
  CaptureFinishExitIntent? get exitIntent => _exitIntent;
  CaptureFinishTerminalOutcome? get terminalOutcome => _terminalOutcome;
  CaptureFinishFailure? get failure => _failure;
  List<CaptureFinishFailure> get cleanupFailures =>
      List<CaptureFinishFailure>.unmodifiable(_cleanupFailures);

  /// Capture admission has exactly one owner and closes at synchronous commit.
  bool get captureAdmissionOpen => _phase == CaptureFinishPhase.capturing;

  /// Once committed, this route must never reveal its capture root again.
  ///
  /// Pre-commit cancellation is intentionally not a tombstone: confirmation
  /// dismissal does not call the coordinator and leaves capture unchanged.
  bool get captureRootTombstoned => switch (_phase) {
    CaptureFinishPhase.capturing || CaptureFinishPhase.cancelled => false,
    _ => true,
  };

  /// The opaque page remains visible from commit through bounded route release.
  bool get shouldShowOpaqueOverlay => switch (_phase) {
    CaptureFinishPhase.committing ||
    CaptureFinishPhase.drainingActiveTicket ||
    CaptureFinishPhase.cameraStopped ||
    CaptureFinishPhase.processing ||
    CaptureFinishPhase.success ||
    CaptureFinishPhase.error ||
    CaptureFinishPhase.exiting => true,
    CaptureFinishPhase.capturing ||
    CaptureFinishPhase.cancelled ||
    CaptureFinishPhase.exited => false,
  };

  /// System back is disabled for every committed non-terminal processing state.
  bool get canPop => switch (_phase) {
    CaptureFinishPhase.committing ||
    CaptureFinishPhase.drainingActiveTicket ||
    CaptureFinishPhase.cameraStopped ||
    CaptureFinishPhase.processing => false,
    _ => true,
  };

  /// Synchronously commits Finish and latches its navigation intent.
  ///
  /// A duplicate call returns null without changing the generation or intent.
  CaptureFinishAttempt? beginFinish({
    required CaptureFinishExitIntent exitIntent,
  }) {
    if (_phase != CaptureFinishPhase.capturing) return null;
    final attempt = CaptureFinishAttempt(++_generation);
    _exitIntent = exitIntent;
    _transition(CaptureFinishPhase.committing);
    return attempt;
  }

  /// Cancels only while capture is still pre-commit.
  CaptureFinishAttempt? cancelBeforeCommit({
    CaptureFinishExitIntent exitIntent = CaptureFinishExitIntent.remainOnRoute,
  }) {
    if (_phase != CaptureFinishPhase.capturing) return null;
    final attempt = CaptureFinishAttempt(++_generation);
    _exitIntent = exitIntent;
    _terminalOutcome = CaptureFinishTerminalOutcome.cancelled;
    _transition(CaptureFinishPhase.cancelled);
    return attempt;
  }

  /// Runs the bounded commit-to-processing handoff.
  ///
  /// Each callback may throw synchronously, complete with an error, or never
  /// complete. All three cases preserve the first and only error terminal.
  /// Once Finish is committed, camera and session cleanup are attempted
  /// exactly once even when the active-ticket drain fails or times out.
  Future<bool> orchestrateToProcessing({
    required CaptureFinishAttempt attempt,
    required FutureOr<void> Function() drainActiveTicket,
    required FutureOr<void> Function() stopCamera,
    required FutureOr<void> Function() beginProcessing,
  }) async {
    if (!_isCurrent(attempt) || _phase != CaptureFinishPhase.committing) {
      return false;
    }

    _transition(CaptureFinishPhase.drainingActiveTicket);
    final drained = await _runAwait(
      attempt: attempt,
      stage: 'drainActiveTicket',
      operation: drainActiveTicket,
    );
    if (!drained) {
      await _runCleanupAwait(
        attempt: attempt,
        stage: 'stopCameraCleanup',
        operation: stopCamera,
      );
      await _runCleanupAwait(
        attempt: attempt,
        stage: 'beginProcessingCleanup',
        operation: beginProcessing,
      );
      return false;
    }
    final cameraStopped = await _runAwait(
      attempt: attempt,
      stage: 'stopCamera',
      operation: stopCamera,
    );
    if (!cameraStopped) {
      await _runCleanupAwait(
        attempt: attempt,
        stage: 'beginProcessingCleanup',
        operation: beginProcessing,
      );
      return false;
    }
    if (!_isCurrentNonTerminal(attempt) ||
        _phase != CaptureFinishPhase.drainingActiveTicket) {
      return false;
    }

    _transition(CaptureFinishPhase.cameraStopped);
    if (!_isCurrentNonTerminal(attempt) ||
        _phase != CaptureFinishPhase.cameraStopped) {
      return false;
    }
    _transition(CaptureFinishPhase.processing);
    if (!await _runAwait(
      attempt: attempt,
      stage: 'beginProcessing',
      operation: beginProcessing,
    )) {
      return false;
    }
    return _isCurrentNonTerminal(attempt) &&
        _phase == CaptureFinishPhase.processing;
  }

  /// Runs one bounded colorize, persistence, cleanup, or release step.
  ///
  /// Only the current processing generation may execute [operation].
  Future<bool> runProcessingStep({
    required CaptureFinishAttempt attempt,
    required String stage,
    required FutureOr<void> Function() operation,
  }) async {
    if (!_isCurrentNonTerminal(attempt) ||
        _phase != CaptureFinishPhase.processing) {
      return false;
    }
    return _runAwait(attempt: attempt, stage: stage, operation: operation);
  }

  /// Records success exactly once and only after processing was entered.
  bool completeSuccess(CaptureFinishAttempt attempt) {
    if (!_isCurrentNonTerminal(attempt) ||
        _phase != CaptureFinishPhase.processing) {
      return false;
    }
    _terminalOutcome = CaptureFinishTerminalOutcome.success;
    _transition(CaptureFinishPhase.success);
    return true;
  }

  /// Records the first error from any committed stage.
  bool completeError(
    CaptureFinishAttempt attempt, {
    required String stage,
    required Object error,
    StackTrace? stackTrace,
    bool timedOut = false,
  }) {
    if (!_isCurrentNonTerminal(attempt) || !_isCommittedNonTerminal(_phase)) {
      return false;
    }
    _failure = CaptureFinishFailure(
      stage: stage,
      error: error,
      stackTrace: stackTrace ?? StackTrace.current,
      timedOut: timedOut,
    );
    _terminalOutcome = CaptureFinishTerminalOutcome.error;
    _transition(CaptureFinishPhase.error);
    return true;
  }

  /// Starts bounded resource release/navigation after a terminal result.
  bool beginExit(CaptureFinishAttempt attempt) {
    // Navigation/reveal happens outside the pure coordinator and may throw.
    // Retrying the same generation while already exiting is idempotent; it
    // does not create a second terminal or regress the monotonic phase.
    if (_isCurrent(attempt) && _phase == CaptureFinishPhase.exiting) {
      return true;
    }
    if (!_isCurrent(attempt) ||
        _terminalOutcome == null ||
        (_phase != CaptureFinishPhase.success &&
            _phase != CaptureFinishPhase.error &&
            _phase != CaptureFinishPhase.cancelled)) {
      return false;
    }
    _transition(CaptureFinishPhase.exiting);
    return true;
  }

  /// Marks the route released. Duplicate and stale callbacks are ignored.
  bool markExited(CaptureFinishAttempt attempt) {
    if (!_isCurrent(attempt) || _phase != CaptureFinishPhase.exiting) {
      return false;
    }
    _transition(CaptureFinishPhase.exited);
    return true;
  }

  Future<bool> _runAwait({
    required CaptureFinishAttempt attempt,
    required String stage,
    required FutureOr<void> Function() operation,
  }) async {
    if (!_isCurrentNonTerminal(attempt)) return false;
    try {
      await Future<void>.sync(operation).timeout(
        stageTimeout,
        onTimeout: () => throw CaptureFinishStageTimeout(stage, stageTimeout),
      );
      return _isCurrentNonTerminal(attempt);
    } catch (error, stackTrace) {
      completeError(
        attempt,
        stage: stage,
        error: error,
        stackTrace: stackTrace,
        timedOut:
            error is CaptureFinishStageTimeout || error is TimeoutException,
      );
      return false;
    }
  }

  Future<bool> _runCleanupAwait({
    required CaptureFinishAttempt attempt,
    required String stage,
    required FutureOr<void> Function() operation,
  }) async {
    if (!_isCurrent(attempt)) return false;
    try {
      await Future<void>.sync(operation).timeout(
        stageTimeout,
        onTimeout: () => throw CaptureFinishStageTimeout(stage, stageTimeout),
      );
      return _isCurrent(attempt);
    } catch (error, stackTrace) {
      _cleanupFailures.add(
        CaptureFinishFailure(
          stage: stage,
          error: error,
          stackTrace: stackTrace,
          timedOut:
              error is CaptureFinishStageTimeout || error is TimeoutException,
        ),
      );
      return false;
    }
  }

  bool _isCurrent(CaptureFinishAttempt attempt) =>
      attempt.generation > 0 && attempt.generation == _generation;

  bool _isCurrentNonTerminal(CaptureFinishAttempt attempt) =>
      _isCurrent(attempt) && _terminalOutcome == null;

  static bool _isCommittedNonTerminal(CaptureFinishPhase phase) =>
      switch (phase) {
        CaptureFinishPhase.committing ||
        CaptureFinishPhase.drainingActiveTicket ||
        CaptureFinishPhase.cameraStopped ||
        CaptureFinishPhase.processing => true,
        _ => false,
      };

  void _transition(CaptureFinishPhase next) {
    if (!_isLegalTransition(_phase, next)) {
      throw StateError('Illegal capture finish transition: $_phase -> $next');
    }
    _phase = next;
    onStateChanged?.call(next);
  }

  static bool _isLegalTransition(
    CaptureFinishPhase from,
    CaptureFinishPhase to,
  ) => switch (from) {
    CaptureFinishPhase.capturing =>
      to == CaptureFinishPhase.committing || to == CaptureFinishPhase.cancelled,
    CaptureFinishPhase.committing =>
      to == CaptureFinishPhase.drainingActiveTicket ||
          to == CaptureFinishPhase.error,
    CaptureFinishPhase.drainingActiveTicket =>
      to == CaptureFinishPhase.cameraStopped || to == CaptureFinishPhase.error,
    CaptureFinishPhase.cameraStopped =>
      to == CaptureFinishPhase.processing || to == CaptureFinishPhase.error,
    CaptureFinishPhase.processing =>
      to == CaptureFinishPhase.success || to == CaptureFinishPhase.error,
    CaptureFinishPhase.success ||
    CaptureFinishPhase.error ||
    CaptureFinishPhase.cancelled => to == CaptureFinishPhase.exiting,
    CaptureFinishPhase.exiting => to == CaptureFinishPhase.exited,
    CaptureFinishPhase.exited => false,
  };
}
