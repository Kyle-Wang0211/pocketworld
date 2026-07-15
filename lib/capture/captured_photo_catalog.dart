import 'dart:io';

/// Returns every user photo currently present in a capture's local photo
/// directory, oldest first.
///
/// The reconstruction ring buffer is deliberately not consulted: eviction
/// and curation may remove a frame from reconstruction consideration, but they
/// never revoke ownership of a JPEG the user captured. Manual shutter v2
/// publishes its JPEG last, so its presence is also the native commit marker.
Future<List<String>> discoverCapturedPhotoPaths(Directory directory) async {
  if (!await directory.exists()) return const <String>[];

  final photos = <({String path, DateTime modified})>[];
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! File) continue;
    final lower = entity.path.toLowerCase();
    if (!lower.endsWith('.jpg') && !lower.endsWith('.jpeg')) continue;
    try {
      if (await entity.length() <= 0) continue;
      photos.add((path: entity.path, modified: await entity.lastModified()));
    } on FileSystemException {
      // A file still being published is not visible as captured yet. The next
      // reconciliation will include it after publication finishes.
    }
  }
  photos.sort((a, b) {
    final byTime = a.modified.compareTo(b.modified);
    return byTime != 0 ? byTime : a.path.compareTo(b.path);
  });
  return List<String>.unmodifiable(photos.map((entry) => entry.path));
}
