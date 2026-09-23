// dense_frame_source_test.dart — _gather's source-selection rule, pinned as a pure function.
// Four cases the phone will actually hit:
//   fresh capture            -> the plain JPEG on disk (unchanged v1 behaviour, no decode at all)
//   PWVA-mastered + run3     -> raw NV12 straight to pwdense_run3 (no JPEG round trip)
//   Lepton archive           -> resolveNv12 says "not mine" -> the old JPEG materialisation
//   PWVA-mastered, no run3   -> NV12 is never even attempted; the old JPEG materialisation carries it
// Plus the bounded pool that runs them: order must survive concurrency, and the bound must hold.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/dense/native_dense_stage_launcher.dart';

void main() {
  group('resolveDenseFrameSource', () {
    test('plain JPEG on disk wins and nothing is materialised', () async {
      var nv12Calls = 0, jpegCalls = 0;
      final d = await resolveDenseFrameSource(
        highresFilename: '0001.jpg',
        plainJpegPath: '/capture/photos_highres/0001.jpg',
        plainExists: true,
        hasRun3: true,
        resolveNv12: (_) async {
          nv12Calls++;
          return null;
        },
        resolveJpeg: (_) async {
          jpegCalls++;
          return null;
        },
      );
      expect(d!.source, DenseFrameSource.plain);
      expect(d.path, '/capture/photos_highres/0001.jpg');
      expect(d.width, 0);
      expect(d.height, 0);
      expect(nv12Calls, 0);
      expect(jpegCalls, 0);
    });

    test('PWVA master + run3 -> NV12, with the decoder size carried along', () async {
      var jpegCalls = 0;
      final d = await resolveDenseFrameSource(
        highresFilename: '0007.jpg',
        plainJpegPath: '/capture/photos_highres/0007.jpg',
        plainExists: false,
        hasRun3: true,
        resolveNv12: (name) async {
          expect(name, '0007.jpg');
          return (file: File('/tmp/cache/sha_0007.jpg.nv12'), width: 1920, height: 1440);
        },
        resolveJpeg: (_) async {
          jpegCalls++;
          return null;
        },
      );
      expect(d!.source, DenseFrameSource.nv12);
      expect(d.path, '/tmp/cache/sha_0007.jpg.nv12');
      expect(d.width, 1920);
      expect(d.height, 1440);
      expect(jpegCalls, 0, reason: 'NV12 succeeded — no JPEG must be produced');
    });

    test('not a PWVA master frame (Lepton archive) -> JPEG materialisation', () async {
      final d = await resolveDenseFrameSource(
        highresFilename: '0002.jpg',
        plainJpegPath: '/capture/photos_highres/0002.jpg',
        plainExists: false,
        hasRun3: true,
        resolveNv12: (_) async => null,
        resolveJpeg: (_) async => File('/tmp/cache/sha_0002.jpg'),
      );
      expect(d!.source, DenseFrameSource.jpegMaterialised);
      expect(d.path, '/tmp/cache/sha_0002.jpg');
    });

    test('no run3 in the framework -> NV12 is never attempted, JPEG carries it', () async {
      var nv12Calls = 0;
      final d = await resolveDenseFrameSource(
        highresFilename: '0003.jpg',
        plainJpegPath: '/capture/photos_highres/0003.jpg',
        plainExists: false,
        hasRun3: false,
        resolveNv12: (_) async {
          nv12Calls++;
          return (file: File('/tmp/cache/sha_0003.jpg.nv12'), width: 4, height: 2);
        },
        resolveJpeg: (_) async => File('/tmp/cache/sha_0003.jpg'),
      );
      expect(d!.source, DenseFrameSource.jpegMaterialised);
      expect(nv12Calls, 0, reason: 'a v1/v2 framework cannot consume an NV12 frame — do not even decode one');
    });

    test('nothing can restore the frame -> null (the caller raises)', () async {
      final d = await resolveDenseFrameSource(
        highresFilename: '0004.jpg',
        plainJpegPath: '/capture/photos_highres/0004.jpg',
        plainExists: false,
        hasRun3: true,
        resolveNv12: (_) async => null,
        resolveJpeg: (_) async => null,
      );
      expect(d, isNull);
    });
  });

  group('mapBoundedConcurrent', () {
    test('keeps the input order even when the slowest item finishes last', () async {
      final items = List<int>.generate(9, (i) => i);
      final out = await mapBoundedConcurrent<int, String>(items, kDenseGatherConcurrency, (i) async {
        await Future<void>.delayed(Duration(milliseconds: (9 - i) * 2));
        return 'f$i';
      });
      expect(out, List<String>.generate(9, (i) => 'f$i'));
    });

    test('never runs more than the bound at once, and does run them concurrently', () async {
      var inFlight = 0, peak = 0;
      final out = await mapBoundedConcurrent<int, int>(List<int>.generate(12, (i) => i), 3, (i) async {
        inFlight++;
        if (inFlight > peak) peak = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        inFlight--;
        return i * 2;
      });
      expect(out, List<int>.generate(12, (i) => i * 2));
      expect(peak, 3);
    });

    test('an empty list is not a deadlock', () async {
      expect(await mapBoundedConcurrent<int, int>(const <int>[], 3, (i) async => i), isEmpty);
    });

    test('a bound larger than the work is fine', () async {
      expect(await mapBoundedConcurrent<int, int>(<int>[1, 2], 8, (i) async => i + 1), <int>[2, 3]);
    });
  });
}
