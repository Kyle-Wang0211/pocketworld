import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

const String kCaptureSourceCleanupCutoffEnvironment =
    'POCKETWORLD_TRIM_LOCAL_CAPTURES_BEFORE';
const String kCaptureSourceCleanupConfirmationEnvironment =
    'POCKETWORLD_TRIM_LOCAL_CAPTURES_CONFIRM';
const String kCaptureSourceCleanupConfirmation = 'KEEP_SPARSE_DELETE_SOURCES';

final RegExp _localCaptureName = RegExp(r'^\u672a\u547d\u540d\((\d+)\)$');
final RegExp _captureDirectoryName = RegExp(r'^cap_\d+$');

class CaptureSourceCleanupResult {
  const CaptureSourceCleanupResult({
    required this.cutoff,
    required this.cleanedCaptureNumbers,
    required this.preservedSparseCaptureNumbers,
    required this.missingSparseCaptureNumbers,
    required this.deletedBytes,
    required this.errors,
  });

  final int cutoff;
  final List<int> cleanedCaptureNumbers;
  final List<int> preservedSparseCaptureNumbers;
  final List<int> missingSparseCaptureNumbers;
  final int deletedBytes;
  final List<String> errors;

  Map<String, Object?> toJson() => <String, Object?>{
    'cutoff': cutoff,
    'cleanedCaptureNumbers': cleanedCaptureNumbers,
    'preservedSparseCaptureNumbers': preservedSparseCaptureNumbers,
    'missingSparseCaptureNumbers': missingSparseCaptureNumbers,
    'deletedBytes': deletedBytes,
    'errors': errors,
  };
}

/// Runs only for an explicitly confirmed detached maintenance launch.
///
/// Normal icon launches never set these process variables and therefore never
/// enter this path. The project index and thumbnails remain untouched. Within
/// each selected local capture directory, only `sfm_sparse.ply` survives so
/// the existing Drafts card continues to open the on-device point-cloud
/// viewer while JPEGs, gray payloads, databases, and replay spools are freed.
Future<CaptureSourceCleanupResult?> runCaptureSourceCleanupIfRequested({
  List<String> arguments = const <String>[],
}) async {
  final cutoffArgument = arguments
      .where(
        (argument) => argument.startsWith('--pw-trim-local-captures-before='),
      )
      .firstOrNull;
  final confirmationArgument = arguments
      .where((argument) => argument.startsWith('--pw-trim-confirm='))
      .firstOrNull;
  final cutoffValue =
      cutoffArgument?.split('=').last ??
      Platform.environment[kCaptureSourceCleanupCutoffEnvironment];
  final confirmation =
      confirmationArgument?.split('=').last ??
      Platform.environment[kCaptureSourceCleanupConfirmationEnvironment];
  final cutoff = int.tryParse(cutoffValue ?? '');
  if (cutoff == null ||
      cutoff <= 0 ||
      confirmation != kCaptureSourceCleanupConfirmation) {
    return null;
  }
  final home = Platform.environment['HOME'];
  final documents = home == null || home.isEmpty
      ? await getApplicationDocumentsDirectory()
      : Directory('$home/Documents');
  final result = await cleanCaptureSourcesBefore(
    documentsDirectory: documents,
    cutoff: cutoff,
  );
  final report = File(
    '${documents.path}/capture_source_cleanup_before_$cutoff.json',
  );
  await report.writeAsString(
    const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      ...result.toJson(),
      'completedAt': DateTime.now().toUtc().toIso8601String(),
    }),
    flush: true,
  );
  return result;
}

Future<CaptureSourceCleanupResult> cleanCaptureSourcesBefore({
  required Directory documentsDirectory,
  required int cutoff,
}) async {
  if (cutoff <= 0) {
    throw ArgumentError.value(cutoff, 'cutoff', 'must be positive');
  }
  final recordsFile = File('${documentsDirectory.path}/scan_records.json');
  final decoded = jsonDecode(await recordsFile.readAsString());
  if (decoded is! List<Object?>) {
    throw const FormatException('scan_records.json must contain a JSON array');
  }

  final selected = <({int number, String id})>[];
  for (final entry in decoded) {
    if (entry is! Map<String, Object?>) continue;
    final name = entry['name'];
    final id = entry['id'];
    if (name is! String || id is! String) continue;
    final match = _localCaptureName.firstMatch(name);
    final number = match == null ? null : int.tryParse(match.group(1)!);
    if (number == null ||
        number >= cutoff ||
        !_captureDirectoryName.hasMatch(id)) {
      continue;
    }
    selected.add((number: number, id: id));
  }
  selected.sort((a, b) => a.number.compareTo(b.number));

  final cleaned = <int>[];
  final preservedSparse = <int>[];
  final missingSparse = <int>[];
  final errors = <String>[];
  var deletedBytes = 0;

  for (final capture in selected) {
    final captureDirectory = Directory(
      '${documentsDirectory.path}/captures/${capture.id}',
    );
    if (!await captureDirectory.exists()) {
      errors.add('cap${capture.number}: capture directory missing');
      continue;
    }
    final sparse = File('${captureDirectory.path}/sfm_sparse.ply');
    final hasSparse = await sparse.exists() && await sparse.length() > 0;
    if (hasSparse) {
      preservedSparse.add(capture.number);
    } else {
      missingSparse.add(capture.number);
    }

    try {
      await for (final entity in captureDirectory.list(followLinks: false)) {
        if (entity is File && entity.path == sparse.path && hasSparse) continue;
        deletedBytes += await _entityByteLength(entity);
        await entity.delete(recursive: true);
      }
      cleaned.add(capture.number);
    } catch (error) {
      errors.add('cap${capture.number}: $error');
    }
  }

  return CaptureSourceCleanupResult(
    cutoff: cutoff,
    cleanedCaptureNumbers: cleaned,
    preservedSparseCaptureNumbers: preservedSparse,
    missingSparseCaptureNumbers: missingSparse,
    deletedBytes: deletedBytes,
    errors: errors,
  );
}

Future<int> _entityByteLength(FileSystemEntity entity) async {
  if (entity is File) return entity.length();
  if (entity is Link) return 0;
  if (entity is! Directory) return 0;
  var total = 0;
  await for (final child in entity.list(recursive: true, followLinks: false)) {
    if (child is File) total += await child.length();
  }
  return total;
}
