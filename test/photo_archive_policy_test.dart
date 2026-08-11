import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_policy.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pw_archive_policy_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('new captures receive a compatible durable policy marker', () async {
    final policy = await PhotoArchivePolicy.writeForNewCapture(tempDir);

    expect(policy.schema, PhotoArchivePolicy.schemaV2);
    expect(policy.codec, PhotoArchivePolicy.leptonCodec);
    expect(policy.mode, PhotoArchivePolicy.jpegReconstructionMode);
    expect(policy.codecVersion, PhotoArchivePolicy.pinnedLeptonVersion);
    expect(policy.codecRevision, PhotoArchivePolicy.pinnedLeptonRevision);
    expect(
      await File('${tempDir.path}/${PhotoArchivePolicy.fileName}').exists(),
      isTrue,
    );

    final reloaded = await PhotoArchivePolicy.readCompatible(tempDir);
    expect(reloaded, isNotNull);
    expect(reloaded!.toJson(), policy.toJson());
  });

  test('legacy capture without marker is never eligible', () async {
    await File('${tempDir.path}/official_sfm_sparse.ply').writeAsBytes([1]);
    await File(
      '${tempDir.path}/official_sfm_sparse_meta.json',
    ).writeAsString('{}');
    await File(
      '${tempDir.path}/official_photo_bundle.json',
    ).writeAsString('{"frames": []}');

    expect(await PhotoArchivePolicy.readCompatible(tempDir), isNull);
  });

  test('malformed and incompatible markers fail closed', () async {
    final marker = File('${tempDir.path}/${PhotoArchivePolicy.fileName}');
    await marker.writeAsString('{broken');
    expect(await PhotoArchivePolicy.readCompatible(tempDir), isNull);

    await marker.writeAsString(
      jsonEncode({
        'schema': 'pw_photo_archive_policy_v99',
        'codec': PhotoArchivePolicy.jpegXlCodec,
        'mode': PhotoArchivePolicy.jpegReconstructionMode,
        'libjxl_revision': PhotoArchivePolicy.pinnedLibjxlRevision,
      }),
    );
    expect(await PhotoArchivePolicy.readCompatible(tempDir), isNull);

    await marker.writeAsString(
      jsonEncode({
        'schema': PhotoArchivePolicy.schemaV1,
        'codec': 'heic',
        'mode': PhotoArchivePolicy.jpegReconstructionMode,
        'libjxl_revision': PhotoArchivePolicy.pinnedLibjxlRevision,
      }),
    );
    expect(await PhotoArchivePolicy.readCompatible(tempDir), isNull);
  });

  test('temporary marker is not mistaken for eligibility', () async {
    await File(
      '${tempDir.path}/${PhotoArchivePolicy.fileName}.tmp',
    ).writeAsString('{}');

    expect(await PhotoArchivePolicy.readCompatible(tempDir), isNull);
  });
}
