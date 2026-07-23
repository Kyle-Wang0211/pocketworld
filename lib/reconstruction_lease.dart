/// Identifies the independently copied reconstruction stack that currently
/// owns the one process-wide native SfM slot.
enum ReconstructionPipeline { selfDeveloped, official }

/// Raised when another reconstruction instance already owns the process-wide
/// SfM slot. This is deliberately explicit so callers never silently fall back
/// to the other pipeline.
final class ReconstructionLeaseBusyException implements Exception {
  const ReconstructionLeaseBusyException({
    required this.activePipeline,
    required this.requestedPipeline,
  });

  final ReconstructionPipeline activePipeline;
  final ReconstructionPipeline requestedPipeline;

  @override
  String toString() =>
      'ReconstructionLeaseBusyException: '
      '${activePipeline.name} reconstruction is still active; '
      'cannot start ${requestedPipeline.name}';
}

/// Identity-checked, process-local ownership of the native SfM worker.
///
/// A repeated acquire by the exact same owner is harmless. Every other owner,
/// including another instance of the same physical pipeline copy, is rejected.
/// Releases are identity checked so stale cleanup cannot unlock a newer worker.
final class ReconstructionLease {
  Object? _owner;
  ReconstructionPipeline? _pipeline;

  ReconstructionPipeline? get activePipeline => _pipeline;

  void acquire({
    required Object owner,
    required ReconstructionPipeline pipeline,
  }) {
    final activeOwner = _owner;
    if (activeOwner == null) {
      _owner = owner;
      _pipeline = pipeline;
      return;
    }
    if (identical(activeOwner, owner)) {
      if (_pipeline != pipeline) {
        throw StateError('A reconstruction lease owner cannot change pipeline');
      }
      return;
    }
    throw ReconstructionLeaseBusyException(
      activePipeline: _pipeline!,
      requestedPipeline: pipeline,
    );
  }

  /// Returns true only when [owner] held and therefore released the lease.
  bool release(Object owner) {
    if (!identical(_owner, owner)) return false;
    _owner = null;
    _pipeline = null;
    return true;
  }
}

/// The sole lease shared by both physically separate Dart reconstruction
/// implementations in this process.
final reconstructionLease = ReconstructionLease();
