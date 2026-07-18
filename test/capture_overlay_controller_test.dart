import 'dart:async';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/capture/capture_overlay_controller.dart';

void main() {
  test('defaults on and updates photo visibility optimistically', () async {
    final nativeCompleted = Completer<void>();
    final calls = <NativeOverlayCall>[];
    final controller = CaptureOverlayController(
      invokeNative: (method, arguments) {
        calls.add(NativeOverlayCall(method, arguments));
        return nativeCompleted.future;
      },
      repushCoverage: () async {},
    );
    addTearDown(controller.dispose);
    var notifications = 0;
    controller.addListener(() => notifications += 1);

    expect(controller.photoCardsVisible, isTrue);
    expect(controller.coveragePointsVisible, isTrue);

    final update = controller.setPhotoCardsVisible(false);

    expect(controller.photoCardsVisible, isFalse);
    expect(controller.coveragePointsVisible, isTrue);
    expect(notifications, 1);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'setPhotoCardsVisible');
    expect(calls.single.arguments, <String, Object?>{'visible': false});

    await controller.setPhotoCardsVisible(false);
    expect(notifications, 1);
    expect(calls, hasLength(1));

    nativeCompleted.complete();
    await update;
  });

  test('coverage visibility is independent and enable awaits repush', () async {
    final enableCompleted = Completer<void>();
    final order = <String>[];
    final calls = <NativeOverlayCall>[];
    var blockEnable = false;
    final controller = CaptureOverlayController(
      invokeNative: (method, arguments) {
        calls.add(NativeOverlayCall(method, arguments));
        order.add(method);
        if (blockEnable && arguments['visible'] == true) {
          return enableCompleted.future;
        }
        return Future<void>.value();
      },
      repushCoverage: () async {
        order.add('repushCoverage');
      },
    );
    addTearDown(controller.dispose);

    await controller.setCoveragePointsVisible(false);
    expect(controller.photoCardsVisible, isTrue);
    expect(controller.coveragePointsVisible, isFalse);
    expect(calls.single.method, 'setFeaturePointsVisible');
    expect(calls.single.arguments, <String, Object?>{'visible': false});
    expect(order, <String>['setFeaturePointsVisible']);

    calls.clear();
    order.clear();
    blockEnable = true;
    final update = controller.setCoveragePointsVisible(true);

    expect(controller.coveragePointsVisible, isTrue);
    expect(order, <String>['setFeaturePointsVisible']);
    expect(calls.single.arguments, <String, Object?>{'visible': true});

    enableCompleted.complete();
    await update;
    expect(order, <String>['setFeaturePointsVisible', 'repushCoverage']);

    calls.clear();
    order.clear();
    await controller.setCoveragePointsVisible(true);
    expect(calls, isEmpty);
    expect(order, isEmpty);
  });

  test('sync sends both current on states then republishes coverage', () async {
    final order = <String>[];
    final calls = <NativeOverlayCall>[];
    final controller = CaptureOverlayController(
      invokeNative: (method, arguments) async {
        calls.add(NativeOverlayCall(method, arguments));
        order.add(method);
      },
      repushCoverage: () async {
        order.add('repushCoverage');
      },
    );
    addTearDown(controller.dispose);

    await controller.syncNativeVisibility();

    expect(order, <String>[
      'setPhotoCardsVisible',
      'setFeaturePointsVisible',
      'repushCoverage',
    ]);
    expect(calls[0].arguments, <String, Object?>{'visible': true});
    expect(calls[1].arguments, <String, Object?>{'visible': true});
  });

  test('sync sends both current off states without republishing', () async {
    final order = <String>[];
    final calls = <NativeOverlayCall>[];
    final controller = CaptureOverlayController(
      invokeNative: (method, arguments) async {
        calls.add(NativeOverlayCall(method, arguments));
        order.add(method);
      },
      repushCoverage: () async {
        order.add('repushCoverage');
      },
    );
    addTearDown(controller.dispose);
    await controller.setPhotoCardsVisible(false);
    await controller.setCoveragePointsVisible(false);
    calls.clear();
    order.clear();

    await controller.syncNativeVisibility();

    expect(order, <String>['setPhotoCardsVisible', 'setFeaturePointsVisible']);
    expect(calls[0].arguments, <String, Object?>{'visible': false});
    expect(calls[1].arguments, <String, Object?>{'visible': false});
  });

  test('glass rect validates, deduplicates, and enables only once', () async {
    final calls = <NativeOverlayCall>[];
    final controller = CaptureOverlayController(
      invokeNative: (method, arguments) async {
        calls.add(NativeOverlayCall(method, arguments));
      },
      repushCoverage: () async {},
    );
    addTearDown(controller.dispose);

    for (final rect in <Rect>[
      Rect.zero,
      const Rect.fromLTWH(10, 20, 0, 52),
      const Rect.fromLTWH(10, 20, 176, -1),
      const Rect.fromLTWH(double.nan, 20, 176, 52),
      const Rect.fromLTWH(10, double.infinity, 176, 52),
      const Rect.fromLTWH(10, 20, double.infinity, 52),
    ]) {
      await controller.reportGlassRect(rect);
    }
    expect(calls, isEmpty);

    const first = Rect.fromLTWH(100, 600, 176, 52);
    await controller.reportGlassRect(first);
    expect(calls, hasLength(2));
    expect(calls[0].method, 'setCaptureGlassRect');
    expect(calls[0].arguments, <String, Object?>{
      'x': 100.0,
      'y': 600.0,
      'width': 176.0,
      'height': 52.0,
    });
    expect(calls[1].method, 'setCaptureGlassEnabled');
    expect(calls[1].arguments, <String, Object?>{'enabled': true});

    await controller.reportGlassRect(first);
    expect(calls, hasLength(2));

    const changed = Rect.fromLTWH(101, 600, 176, 52);
    await controller.reportGlassRect(changed);
    expect(calls, hasLength(3));
    expect(calls.last.method, 'setCaptureGlassRect');
    expect(calls.last.arguments, <String, Object?>{
      'x': 101.0,
      'y': 600.0,
      'width': 176.0,
      'height': 52.0,
    });
    expect(
      calls.where((call) => call.method == 'setCaptureGlassEnabled'),
      hasLength(1),
    );
  });

  test('detach disables glass and restores native defaults once', () async {
    final calls = <NativeOverlayCall>[];
    final controller = CaptureOverlayController(
      invokeNative: (method, arguments) async {
        calls.add(NativeOverlayCall(method, arguments));
      },
      repushCoverage: () async {},
    );
    addTearDown(controller.dispose);
    await controller.setPhotoCardsVisible(false);
    await controller.setCoveragePointsVisible(false);
    calls.clear();

    await controller.detach();
    await controller.detach();

    expect(calls.map((call) => call.method), <String>[
      'setCaptureGlassEnabled',
      'setPhotoCardsVisible',
      'setFeaturePointsVisible',
    ]);
    expect(calls[0].arguments, <String, Object?>{'enabled': false});
    expect(calls[1].arguments, <String, Object?>{'visible': true});
    expect(calls[2].arguments, <String, Object?>{'visible': true});
  });

  test('glass rect reports after detach are ignored', () async {
    final calls = <NativeOverlayCall>[];
    final controller = CaptureOverlayController(
      invokeNative: (method, arguments) async {
        calls.add(NativeOverlayCall(method, arguments));
      },
      repushCoverage: () async {},
    );
    addTearDown(controller.dispose);
    await controller.detach();
    calls.clear();

    await controller.reportGlassRect(const Rect.fromLTWH(0, 0, 176, 52));

    expect(calls, isEmpty);
  });

  test('visibility setters and sync are no-ops after detach', () async {
    final calls = <NativeOverlayCall>[];
    var repushAttempts = 0;
    var notifications = 0;
    final controller = CaptureOverlayController(
      invokeNative: (method, arguments) async {
        calls.add(NativeOverlayCall(method, arguments));
      },
      repushCoverage: () async {
        repushAttempts += 1;
      },
    );
    addTearDown(controller.dispose);
    controller.addListener(() => notifications += 1);
    await controller.detach();
    calls.clear();

    await controller.setPhotoCardsVisible(false);
    await controller.setCoveragePointsVisible(false);
    await controller.syncNativeVisibility();

    expect(calls, isEmpty);
    expect(repushAttempts, 0);
    expect(notifications, 0);
    expect(controller.photoCardsVisible, isTrue);
    expect(controller.coveragePointsVisible, isTrue);
  });

  test(
    'detach fences repush and resets after blocked coverage enable',
    () async {
      final enableCompleted = Completer<void>();
      final calls = <NativeOverlayCall>[];
      var blockEnable = false;
      var repushAttempts = 0;
      final controller = CaptureOverlayController(
        invokeNative: (method, arguments) {
          calls.add(NativeOverlayCall(method, arguments));
          if (blockEnable &&
              method == 'setFeaturePointsVisible' &&
              arguments['visible'] == true) {
            return enableCompleted.future;
          }
          return Future<void>.value();
        },
        repushCoverage: () async {
          repushAttempts += 1;
        },
      );
      addTearDown(controller.dispose);
      await controller.setCoveragePointsVisible(false);
      calls.clear();
      blockEnable = true;

      final enable = controller.setCoveragePointsVisible(true);
      expect(calls.map((call) => call.method), <String>[
        'setFeaturePointsVisible',
      ]);
      final detach = controller.detach();
      expect(calls.map((call) => call.method), <String>[
        'setFeaturePointsVisible',
        'setCaptureGlassEnabled',
      ]);
      expect(repushAttempts, 0);

      enableCompleted.complete();
      await enable;
      await detach;

      expect(calls.map((call) => call.method), <String>[
        'setFeaturePointsVisible',
        'setCaptureGlassEnabled',
        'setPhotoCardsVisible',
        'setFeaturePointsVisible',
      ]);
      expect(calls[1].arguments, <String, Object?>{'enabled': false});
      expect(calls[2].arguments, <String, Object?>{'visible': true});
      expect(calls[3].arguments, <String, Object?>{'visible': true});
      expect(repushAttempts, 0);
    },
  );

  test('detach stops a blocked sync and makes reset calls final', () async {
    final photoCompleted = Completer<void>();
    final calls = <NativeOverlayCall>[];
    var blockPhoto = false;
    var repushAttempts = 0;
    final controller = CaptureOverlayController(
      invokeNative: (method, arguments) {
        calls.add(NativeOverlayCall(method, arguments));
        if (blockPhoto &&
            method == 'setPhotoCardsVisible' &&
            arguments['visible'] == false) {
          return photoCompleted.future;
        }
        return Future<void>.value();
      },
      repushCoverage: () async {
        repushAttempts += 1;
      },
    );
    addTearDown(controller.dispose);
    await controller.setPhotoCardsVisible(false);
    await controller.setCoveragePointsVisible(false);
    calls.clear();
    blockPhoto = true;

    final sync = controller.syncNativeVisibility();
    expect(calls.map((call) => call.method), <String>['setPhotoCardsVisible']);
    final detach = controller.detach();
    expect(calls.map((call) => call.method), <String>[
      'setPhotoCardsVisible',
      'setCaptureGlassEnabled',
    ]);

    photoCompleted.complete();
    await sync;
    await detach;

    expect(calls.map((call) => call.method), <String>[
      'setPhotoCardsVisible',
      'setCaptureGlassEnabled',
      'setPhotoCardsVisible',
      'setFeaturePointsVisible',
    ]);
    expect(calls[0].arguments, <String, Object?>{'visible': false});
    expect(calls[1].arguments, <String, Object?>{'enabled': false});
    expect(calls[2].arguments, <String, Object?>{'visible': true});
    expect(calls[3].arguments, <String, Object?>{'visible': true});
    expect(repushAttempts, 0);
  });

  test('detach fences an in-flight glass rect before it can enable', () async {
    final rectCompleted = Completer<void>();
    final calls = <NativeOverlayCall>[];
    final controller = CaptureOverlayController(
      invokeNative: (method, arguments) {
        calls.add(NativeOverlayCall(method, arguments));
        if (method == 'setCaptureGlassRect') return rectCompleted.future;
        return Future<void>.value();
      },
      repushCoverage: () async {},
    );
    addTearDown(controller.dispose);

    final report = controller.reportGlassRect(
      const Rect.fromLTWH(0, 0, 176, 52),
    );
    expect(calls.map((call) => call.method), <String>['setCaptureGlassRect']);

    await controller.detach();
    expect(calls.map((call) => call.method), <String>[
      'setCaptureGlassRect',
      'setCaptureGlassEnabled',
      'setPhotoCardsVisible',
      'setFeaturePointsVisible',
    ]);
    expect(calls[1].arguments, <String, Object?>{'enabled': false});

    rectCompleted.complete();
    await report;
    expect(calls.map((call) => call.method), <String>[
      'setCaptureGlassRect',
      'setCaptureGlassEnabled',
      'setPhotoCardsVisible',
      'setFeaturePointsVisible',
    ]);
    expect(calls[1].arguments, <String, Object?>{'enabled': false});
  });

  test('channel and repush errors never escape or roll back intent', () async {
    final attempts = <String>[];
    var repushAttempts = 0;
    final controller = CaptureOverlayController(
      invokeNative: (method, arguments) {
        attempts.add(method);
        throw StateError('channel unavailable');
      },
      repushCoverage: () {
        repushAttempts += 1;
        throw StateError('repush unavailable');
      },
    );
    addTearDown(controller.dispose);

    await expectLater(controller.setPhotoCardsVisible(false), completes);
    await expectLater(controller.setCoveragePointsVisible(false), completes);
    await expectLater(controller.setCoveragePointsVisible(true), completes);
    await expectLater(controller.syncNativeVisibility(), completes);
    await expectLater(
      controller.reportGlassRect(const Rect.fromLTWH(0, 0, 176, 52)),
      completes,
    );
    await expectLater(controller.detach(), completes);
    await expectLater(controller.detach(), completes);

    expect(controller.photoCardsVisible, isFalse);
    expect(controller.coveragePointsVisible, isTrue);
    expect(attempts, <String>[
      'setPhotoCardsVisible',
      'setFeaturePointsVisible',
      'setFeaturePointsVisible',
      'setPhotoCardsVisible',
      'setFeaturePointsVisible',
      'setCaptureGlassRect',
      'setCaptureGlassEnabled',
      'setCaptureGlassEnabled',
      'setPhotoCardsVisible',
      'setFeaturePointsVisible',
    ]);
    expect(repushAttempts, 2);
  });
}
