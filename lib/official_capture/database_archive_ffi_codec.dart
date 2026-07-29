import 'dart:io';

import 'database_archive_codec.dart';

/// Production slot for the pinned native ZPAQ bridge.
///
/// Native support is enabled only after the exact bridge identity is linked.
class ZpaqFfiDatabaseArchiveCodec implements DatabaseArchiveCodec {
  @override
  bool get isSupported => false;

  @override
  Future<void> compress({
    required File sourceDatabase,
    required File destinationArchive,
  }) {
    throw UnsupportedError('pinned ZPAQ bridge is unavailable');
  }

  @override
  Future<void> decompress({
    required File sourceArchive,
    required File destinationDatabase,
  }) {
    throw UnsupportedError('pinned ZPAQ bridge is unavailable');
  }

  @override
  void requestCancellation() {}
}
