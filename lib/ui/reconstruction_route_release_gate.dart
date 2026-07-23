/// Serializes terminal reconstruction teardown and reveals the enabled root
/// only after every owned resource has been released.
final class ReconstructionRouteReleaseGate {
  bool _isReleasing = false;

  bool get isReleasing => _isReleasing;

  Future<bool> release({
    required Future<void> Function() releaseResources,
    required void Function() revealRoot,
  }) async {
    if (_isReleasing) return false;
    _isReleasing = true;
    try {
      await releaseResources();
      revealRoot();
      return true;
    } finally {
      _isReleasing = false;
    }
  }
}
