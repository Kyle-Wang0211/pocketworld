import 'dart:io';

/// File-oriented primitive for the pinned portable database archive codec.
abstract interface class DatabaseArchiveCodec {
  bool get isSupported;

  Future<void> compress({
    required File sourceDatabase,
    required File destinationArchive,
  });

  Future<void> decompress({
    required File sourceArchive,
    required File destinationDatabase,
  });

  /// Requests cooperative interruption of an in-flight native operation.
  void requestCancellation();
}

/// Raised when native work stopped because foreground work took priority.
final class DatabaseArchiveCancelled implements Exception {
  const DatabaseArchiveCancelled();
}
