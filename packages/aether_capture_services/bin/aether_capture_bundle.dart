import 'dart:io';

import 'package:aether_capture_services/aether_capture_services.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln(
        'usage: dart run bin/aether_capture_bundle.dart <photo-bundle-dir>');
    exitCode = 64;
    return;
  }

  final bundleDir = Directory(args.single);
  if (!bundleDir.existsSync()) {
    stderr.writeln('photo bundle directory does not exist: ${bundleDir.path}');
    exitCode = 66;
    return;
  }

  final manifestFile = File(_join(bundleDir.path, 'photo_bundle.json'));
  if (!manifestFile.existsSync()) {
    stderr.writeln('missing photo_bundle.json in ${bundleDir.path}');
    exitCode = 66;
    return;
  }

  final result = await const PhotoBundleDerivationService().deriveDirectory(
    bundleDir,
  );
  stdout.writeln(
    'photo bundle checked: status=${result.status} frames=${result.frameCount} edges=${result.edgeCount} colmap_frames=${result.colmapFrameCount}',
  );
}

String _join(String left, String right) {
  final normalizedRight = right.split('/').join(Platform.pathSeparator);
  if (left.endsWith(Platform.pathSeparator)) {
    return '$left$normalizedRight';
  }
  return '$left${Platform.pathSeparator}$normalizedRight';
}
