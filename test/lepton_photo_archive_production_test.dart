import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_codec.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_manifest.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_policy.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_resolver.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_transaction.dart';

void main() {
  late Directory root;
  late Directory highres;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pw_lepton_production_');
    highres = Directory('${root.path}/photos_highres');
    await highres.create(recursive: true);
    await File('${root.path}/official_photo_bundle.json').writeAsString(
      jsonEncode({
        'schemaVersion': 'aether_photo_bundle_v1',
        'photosHighresDir': 'photos_highres',
        'frames': [
          {'highresFilename': 'frame.jpg'},
        ],
      }),
      flush: true,
    );
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('future captures select pinned official Lepton v0.5.8', () async {
    final policy = await PhotoArchivePolicy.writeForNewCapture(root);

    expect(policy.schema, PhotoArchivePolicy.schemaV2);
    expect(policy.codec, PhotoArchivePolicy.leptonCodec);
    expect(policy.codecVersion, PhotoArchivePolicy.pinnedLeptonVersion);
    expect(policy.codecRevision, PhotoArchivePolicy.pinnedLeptonRevision);
    expect(policy.archiveSuffix, '.lep');

    final json =
        jsonDecode(
              await File(
                '${root.path}/${PhotoArchivePolicy.fileName}',
              ).readAsString(),
            )
            as Map<String, Object?>;
    expect(json['codec_version'], PhotoArchivePolicy.pinnedLeptonVersion);
    expect(json['codec_revision'], PhotoArchivePolicy.pinnedLeptonRevision);
    expect(json, isNot(contains('libjxl_revision')));
  });

  test('legacy v1 JPEG XL policy remains readable and pinned', () async {
    await File('${root.path}/${PhotoArchivePolicy.fileName}').writeAsString(
      jsonEncode({
        'schema': PhotoArchivePolicy.schemaV1,
        'codec': PhotoArchivePolicy.jpegXlCodec,
        'mode': PhotoArchivePolicy.jpegReconstructionMode,
        'libjxl_revision': PhotoArchivePolicy.pinnedLibjxlRevision,
        'created_at': '2026-07-30T00:00:00.000Z',
      }),
      flush: true,
    );

    final policy = await PhotoArchivePolicy.readCompatible(root);

    expect(policy, isNotNull);
    expect(policy!.codec, PhotoArchivePolicy.jpegXlCodec);
    expect(policy.codecVersion, PhotoArchivePolicy.pinnedLibjxlVersion);
    expect(policy.codecRevision, PhotoArchivePolicy.pinnedLibjxlRevision);
    expect(policy.archiveSuffix, '.jxl');
  });

  test('new archive publishes .lep and records codec identity', () async {
    final original = List<int>.filled(8192, 42);
    final source = File('${highres.path}/frame.jpg');
    await source.writeAsBytes(original, flush: true);
    await PhotoArchivePolicy.writeForNewCapture(root);
    final lepton = _TaggedZlibCodec('lepton');
    final legacyJxl = _TaggedZlibCodec('jpeg-xl');

    final result = await PhotoArchiveTransaction(
      codec: lepton,
      codecsByName: {
        PhotoArchivePolicy.leptonCodec: lepton,
        PhotoArchivePolicy.jpegXlCodec: legacyJxl,
      },
    ).archiveCapture(root);

    expect(result.archivedNames, ['frame.jpg']);
    expect(await source.exists(), isFalse);
    expect(await File('${source.path}.lep').exists(), isTrue);
    expect(await File('${source.path}.jxl').exists(), isFalse);
    expect(lepton.encodeCalls, 1);
    expect(legacyJxl.encodeCalls, 0);
    final manifest = await PhotoArchiveManifest.read(root);
    expect(manifest, isNotNull);
    expect(manifest!.schema, PhotoArchiveManifest.schemaV2);
    expect(manifest.codec, PhotoArchivePolicy.leptonCodec);
    expect(manifest.codecVersion, PhotoArchivePolicy.pinnedLeptonVersion);
    expect(manifest.codecRevision, PhotoArchivePolicy.pinnedLeptonRevision);
    expect(
      manifest.entries['frame.jpg']!.archiveRelativePath,
      'photos_highres/frame.jpg.lep',
    );
  });

  test('resolver routes v2 Lepton archive to Lepton only', () async {
    final lepton = _TaggedZlibCodec('lepton');
    final legacyJxl = _TaggedZlibCodec('jpeg-xl');
    final codecs = <String, PhotoArchiveCodec>{
      PhotoArchivePolicy.leptonCodec: lepton,
      PhotoArchivePolicy.jpegXlCodec: legacyJxl,
    };
    final original = List<int>.filled(4096, 9);
    final source = File('${highres.path}/frame.jpg');
    await source.writeAsBytes(original, flush: true);
    final policy = await PhotoArchivePolicy.writeForNewCapture(root);
    final archive = File('${source.path}.lep');
    await lepton.encodeJpeg(sourceJpeg: source, destinationJxl: archive);
    final archiveBytes = await archive.readAsBytes();
    final manifest = PhotoArchiveManifest.forPolicy(
      policy,
      entries: {
        'frame.jpg': PhotoArchiveEntry(
          sourceRelativePath: 'photos_highres/frame.jpg',
          sourceBytes: original.length,
          sourceSha256: sha256.convert(original).toString(),
          archiveRelativePath: 'photos_highres/frame.jpg.lep',
          archiveBytes: archiveBytes.length,
          archiveSha256: sha256.convert(archiveBytes).toString(),
          status: PhotoArchiveEntryStatus.verified,
          verifiedAt: '2026-08-02T00:00:00.000Z',
        ),
      },
    );
    await manifest.writeAtomic(root);
    await source.delete();

    final resolved =
        await PhotoArchiveResolver(
          codec: lepton,
          codecsByName: codecs,
        ).resolveJpeg(
          captureDirectory: root,
          highresFilename: 'frame.jpg',
          cacheDirectory: Directory('${root.path}/cache'),
        );

    expect(resolved, isNotNull);
    expect(await resolved!.readAsBytes(), original);
    expect(lepton.reconstructCalls, 1);
    expect(legacyJxl.reconstructCalls, 0);
  });

  test('resolver routes legacy v1 JXL archive to JXL only', () async {
    final lepton = _TaggedZlibCodec('lepton');
    final legacyJxl = _TaggedZlibCodec('jpeg-xl');
    final codecs = <String, PhotoArchiveCodec>{
      PhotoArchivePolicy.leptonCodec: lepton,
      PhotoArchivePolicy.jpegXlCodec: legacyJxl,
    };
    final original = List<int>.generate(4096, (i) => i & 0xff);
    final source = File('${highres.path}/frame.jpg');
    await source.writeAsBytes(original, flush: true);
    await File('${root.path}/${PhotoArchivePolicy.fileName}').writeAsString(
      jsonEncode({
        'schema': PhotoArchivePolicy.schemaV1,
        'codec': PhotoArchivePolicy.jpegXlCodec,
        'mode': PhotoArchivePolicy.jpegReconstructionMode,
        'libjxl_revision': PhotoArchivePolicy.pinnedLibjxlRevision,
        'created_at': '2026-07-30T00:00:00.000Z',
      }),
      flush: true,
    );
    final policy = await PhotoArchivePolicy.readCompatible(root);
    expect(policy, isNotNull);
    final archive = File('${source.path}.jxl');
    await legacyJxl.encodeJpeg(sourceJpeg: source, destinationJxl: archive);
    final archiveBytes = await archive.readAsBytes();
    await PhotoArchiveManifest.forPolicy(
      policy!,
      entries: {
        'frame.jpg': PhotoArchiveEntry(
          sourceRelativePath: 'photos_highres/frame.jpg',
          sourceBytes: original.length,
          sourceSha256: sha256.convert(original).toString(),
          archiveRelativePath: 'photos_highres/frame.jpg.jxl',
          archiveBytes: archiveBytes.length,
          archiveSha256: sha256.convert(archiveBytes).toString(),
          status: PhotoArchiveEntryStatus.verified,
          verifiedAt: '2026-08-02T00:00:00.000Z',
        ),
      },
    ).writeAtomic(root);
    await source.delete();

    final resolved =
        await PhotoArchiveResolver(
          codec: lepton,
          codecsByName: codecs,
        ).resolveJpeg(
          captureDirectory: root,
          highresFilename: 'frame.jpg',
          cacheDirectory: Directory('${root.path}/cache'),
        );

    expect(resolved, isNotNull);
    expect(await resolved!.readAsBytes(), original);
    expect(legacyJxl.reconstructCalls, 1);
    expect(lepton.reconstructCalls, 0);
  });

  test('production wiring keeps Lepton primary and JXL legacy decode', () {
    final runtime = File(
      'lib/official_capture/photo_archive_runtime.dart',
    ).readAsStringSync();
    final resume = File(
      'lib/official_capture/sfm_resume.dart',
    ).readAsStringSync();
    final project = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    final deviceLinkSettings = [
      File('ios/Flutter/Debug.xcconfig').readAsStringSync(),
      File('ios/Flutter/Release.xcconfig').readAsStringSync(),
    ].join('\n');
    final native = File('native/lepton_jpeg_ffi/src/lib.rs').readAsStringSync();

    expect(runtime, contains('LeptonFfiPhotoArchiveCodec'));
    expect(runtime, contains('legacyJxlPhotoArchiveCodec'));
    expect(runtime, contains('photoArchiveCodecsByName'));
    expect(resume, contains('codecsByName: photoArchiveCodecsByName'));
    expect(project, contains('libpw_lepton_jpeg_ffi.a'));
    expect(deviceLinkSettings, contains('-Wl,-u,_pw_lepton_request_cancel'));
    expect(native, contains('pw_lepton_cancellation_generation'));
    expect(native, contains('pw_lepton_request_cancel'));
  });
}

final class _TaggedZlibCodec implements PhotoArchiveCodec {
  _TaggedZlibCodec(this.tag);

  final String tag;
  int encodeCalls = 0;
  int reconstructCalls = 0;

  @override
  bool get isSupported => true;

  @override
  Future<void> encodeJpeg({
    required File sourceJpeg,
    required File destinationJxl,
  }) async {
    encodeCalls++;
    await destinationJxl.writeAsBytes(
      ZLibCodec().encode(await sourceJpeg.readAsBytes()),
      flush: true,
    );
  }

  @override
  Future<void> reconstructJpeg({
    required File sourceJxl,
    required File destinationJpeg,
  }) async {
    reconstructCalls++;
    await destinationJpeg.writeAsBytes(
      ZLibCodec().decode(await sourceJxl.readAsBytes()),
      flush: true,
    );
  }

  @override
  void requestCancellation() {}
}
