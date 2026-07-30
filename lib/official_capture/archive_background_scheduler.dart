abstract interface class ArchiveBackgroundScheduler {
  Future<void> schedule();

  Future<void> cancelScheduled();
}

class NoopArchiveBackgroundScheduler implements ArchiveBackgroundScheduler {
  const NoopArchiveBackgroundScheduler();

  @override
  Future<void> cancelScheduled() async {}

  @override
  Future<void> schedule() async {}
}
