import 'dart:io';

import 'photo_archive_policy.dart';

/// Removes capture-time AR card textures from one explicitly marked capture.
///
/// The fixed child path and policy check make this safe to call from both the
/// immediate draft-persistence path and cold startup reconciliation.
Future<bool> removeTransientCapturePreviews(Directory captureDirectory) async {
  if (await PhotoArchivePolicy.readCompatible(captureDirectory) == null) {
    return false;
  }
  final previewsPath = '${captureDirectory.path}/previews';
  try {
    final type = await FileSystemEntity.type(previewsPath, followLinks: false);
    if (type == FileSystemEntityType.notFound) return false;
    if (type == FileSystemEntityType.link) {
      await Link(previewsPath).delete();
      return true;
    }
    if (type != FileSystemEntityType.directory) return false;
    await Directory(previewsPath).delete(recursive: true);
    return true;
  } on FileSystemException {
    return false;
  }
}
