import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/archive_background_runtime.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_codec.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_coordinator.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory documentsDirectory;
  late MethodChannel channel;
  late List<String> outboundMethods;

  setUp(() async {
    documentsDirectory = await Directory.systemTemp.createTemp(
      'pw_archive_background_runtime_',
    );
    channel = const MethodChannel('pw_archive_background_runtime_test');
    outboundMethods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          outboundMethods.add(call.method);
          return null;
        });
  });

  tearDown(() async {
    channel.setMethodCallHandler(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (await documentsDirectory.exists()) {
      await documentsDirectory.delete(recursive: true);
    }
  });

  Future<Directory> createCapture(
    String name, {
    List<String> photos = const <String>['frame.jpg'],
  }) async {
    final capture = Directory(
      '${documentsDirectory.path}/captures_official/$name',
    );
    final highres = Directory('${capture.path}/photos_highres');
    await highres.create(recursive: true);
    await PhotoArchivePolicy.writeForNewCapture(capture);
    for (var index = 0; index < photos.length; index++) {
      await File(
        '${highres.path}/${photos[index]}',
      ).writeAsBytes(List<int>.filled(8192, index + 1), flush: true);
    }
    await File('${capture.path}/official_photo_bundle.json').writeAsString(
      jsonEncode({
        'schemaVersion': 'aether_photo_bundle_v1',
        'photosHighresDir': 'photos_highres',
        'frames': [
          for (final photo in photos) {'highresFilename': photo},
        ],
      }),
      flush: true,
    );
    await File(
      '${capture.path}/official_sfm_sparse.ply',
    ).writeAsBytes(const <int>[1], flush: true);
    await File(
      '${capture.path}/official_sfm_sparse_meta.json',
    ).writeAsString('{"n_points":1}', flush: true);
    return capture;
  }

  test('reports ready before accepting a native background run', () async {
    final capture = await createCapture('ready-run');
    final scheduler = MethodChannelArchiveBackgroundScheduler(channel: channel);
    final coordinator = PhotoArchiveCoordinator(
      codec: _RuntimeZlibCodec(),
      backgroundScheduler: scheduler,
    );
    final runtime = OfficialArchiveBackgroundRuntime(
      channel: channel,
      coordinator: coordinator,
      documentsDirectory: () async => documentsDirectory,
    );

    await runtime.initialize();
    final result =
        await _invokeDart(channel, 'runColdArchive') as Map<Object?, Object?>;

    expect(outboundMethods.first, 'ready');
    expect(result['success'], isTrue);
    expect(result['work_remaining'], isFalse);
    expect(
      await File('${capture.path}/photos_highres/frame.jpg').exists(),
      isFalse,
    );
    expect(
      await File('${capture.path}/photos_highres/frame.jpg.lep').exists(),
      isTrue,
    );
  });

  test('native expiration cancels the in-flight photo', () async {
    final capture = await createCapture(
      'expired',
      photos: const <String>['one.jpg', 'two.jpg'],
    );
    final codec = _BlockingRuntimeCodec();
    final scheduler = MethodChannelArchiveBackgroundScheduler(channel: channel);
    final coordinator = PhotoArchiveCoordinator(
      codec: codec,
      backgroundScheduler: scheduler,
    );
    final runtime = OfficialArchiveBackgroundRuntime(
      channel: channel,
      coordinator: coordinator,
      documentsDirectory: () async => documentsDirectory,
    );
    await runtime.initialize();

    final running = _invokeDart(channel, 'runColdArchive');
    await codec.encodeStarted.future;
    final cancelResult =
        await _invokeDart(channel, 'cancelColdArchive')
            as Map<Object?, Object?>;
    codec.allowEncode.complete();
    final runResult = await running as Map<Object?, Object?>;

    expect(cancelResult['accepted'], isTrue);
    expect(runResult['success'], isTrue);
    expect(runResult['work_remaining'], isTrue);
    expect(codec.cancellationRequests, 1);
    expect(
      await File('${capture.path}/photos_highres/one.jpg').exists(),
      isTrue,
    );
    expect(
      await File('${capture.path}/photos_highres/two.jpg').exists(),
      isTrue,
    );
    expect(coordinator.hasPendingWork, isTrue);
  });
}

Future<Object?> _invokeDart(
  MethodChannel channel,
  String method, [
  Object? arguments,
]) async {
  final completer = Completer<Object?>();
  final message = channel.codec.encodeMethodCall(MethodCall(method, arguments));
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(channel.name, message, (ByteData? response) {
        if (response == null) {
          completer.complete(null);
          return;
        }
        try {
          completer.complete(channel.codec.decodeEnvelope(response));
        } catch (error, stackTrace) {
          completer.completeError(error, stackTrace);
        }
      });
  return completer.future;
}

class _RuntimeZlibCodec implements PhotoArchiveCodec {
  @override
  bool get isSupported => true;

  @override
  Future<void> encodeJpeg({
    required File sourceJpeg,
    required File destinationJxl,
  }) async {
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
    await destinationJpeg.writeAsBytes(
      ZLibCodec().decode(await sourceJxl.readAsBytes()),
      flush: true,
    );
  }

  @override
  void requestCancellation() {}
}

class _BlockingRuntimeCodec extends _RuntimeZlibCodec {
  final Completer<void> encodeStarted = Completer<void>();
  final Completer<void> allowEncode = Completer<void>();
  int cancellationRequests = 0;

  @override
  Future<void> encodeJpeg({
    required File sourceJpeg,
    required File destinationJxl,
  }) async {
    encodeStarted.complete();
    await allowEncode.future;
    await super.encodeJpeg(
      sourceJpeg: sourceJpeg,
      destinationJxl: destinationJxl,
    );
  }

  @override
  void requestCancellation() {
    cancellationRequests++;
  }
}
