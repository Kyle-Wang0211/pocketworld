import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';

typedef NativeOverlayInvoker =
    Future<void> Function(String method, Map<String, Object?> arguments);

/// A recorded native method invocation used by controller tests.
@immutable
class NativeOverlayCall {
  final String method;
  final Map<String, Object?> arguments;

  const NativeOverlayCall(this.method, this.arguments);
}

/// Coordinates Flutter overlay intent with the native AR preview.
class CaptureOverlayController extends ChangeNotifier {
  final NativeOverlayInvoker _invokeNative;
  final Future<void> Function() _repushCoverage;

  bool _photoCardsVisible = true;
  bool _coveragePointsVisible = true;
  Rect? _lastGlassRect;
  bool _glassEnableSent = false;
  bool _detached = false;
  Future<void> _visibilityTail = Future<void>.value();
  int _pendingVisibilityOperations = 0;
  Completer<void>? _detachCompleter;

  CaptureOverlayController({
    required NativeOverlayInvoker invokeNative,
    required Future<void> Function() repushCoverage,
  }) : _invokeNative = invokeNative,
       _repushCoverage = repushCoverage;

  bool get photoCardsVisible => _photoCardsVisible;
  bool get coveragePointsVisible => _coveragePointsVisible;

  Future<void> setPhotoCardsVisible(bool visible) {
    if (_detached || _photoCardsVisible == visible) {
      return Future<void>.value();
    }

    _photoCardsVisible = visible;
    notifyListeners();
    return _enqueueVisibility(() async {
      if (_detached) return;
      await _bestEffortNative('setPhotoCardsVisible', <String, Object?>{
        'visible': visible,
      });
    });
  }

  Future<void> setCoveragePointsVisible(bool visible) {
    if (_detached || _coveragePointsVisible == visible) {
      return Future<void>.value();
    }

    _coveragePointsVisible = visible;
    notifyListeners();
    return _enqueueVisibility(() async {
      if (_detached) return;
      await _bestEffortNative('setFeaturePointsVisible', <String, Object?>{
        'visible': visible,
      });
      if (_detached) return;
      if (visible) {
        await _bestEffortRepushCoverage();
        if (_detached) return;
      }
    });
  }

  Future<void> reportGlassRect(Rect rect) async {
    if (_detached || !_isValidGlassRect(rect) || _lastGlassRect == rect) return;

    _lastGlassRect = rect;
    final shouldEnable = !_glassEnableSent;
    _glassEnableSent = true;

    await _bestEffortNative('setCaptureGlassRect', <String, Object?>{
      'x': rect.left,
      'y': rect.top,
      'width': rect.width,
      'height': rect.height,
    });
    if (shouldEnable && !_detached) {
      await _bestEffortNative('setCaptureGlassEnabled', <String, Object?>{
        'enabled': true,
      });
    }
  }

  Future<void> syncNativeVisibility() {
    if (_detached) return Future<void>.value();

    final photoCardsVisible = _photoCardsVisible;
    final coveragePointsVisible = _coveragePointsVisible;
    return _enqueueVisibility(() async {
      if (_detached) return;
      await _bestEffortNative('setPhotoCardsVisible', <String, Object?>{
        'visible': photoCardsVisible,
      });
      if (_detached) return;
      await _bestEffortNative('setFeaturePointsVisible', <String, Object?>{
        'visible': coveragePointsVisible,
      });
      if (_detached) return;
      if (coveragePointsVisible) {
        await _bestEffortRepushCoverage();
        if (_detached) return;
      }
    });
  }

  Future<void> detach() {
    final existingDetach = _detachCompleter;
    if (existingDetach != null) return existingDetach.future;

    _detached = true;
    final detachCompleter = Completer<void>();
    _detachCompleter = detachCompleter;
    final glassDisable = _bestEffortNative(
      'setCaptureGlassEnabled',
      <String, Object?>{'enabled': false},
    );
    final visibilityReset = _enqueueVisibility(() async {
      await _bestEffortNative('setPhotoCardsVisible', <String, Object?>{
        'visible': true,
      });
      await _bestEffortNative('setFeaturePointsVisible', <String, Object?>{
        // Native idles with coverage off; fresh Dart capture intent remains on.
        'visible': false,
      });
    });
    Future.wait<void>([glassDisable, visibilityReset]).then<void>((_) {
      detachCompleter.complete();
    });
    return detachCompleter.future;
  }

  bool _isValidGlassRect(Rect rect) {
    return rect.left.isFinite &&
        rect.top.isFinite &&
        rect.width.isFinite &&
        rect.height.isFinite &&
        rect.width > 0 &&
        rect.height > 0;
  }

  Future<void> _bestEffortNative(
    String method,
    Map<String, Object?> arguments,
  ) async {
    try {
      await _invokeNative(method, arguments);
    } catch (_) {}
  }

  Future<void> _bestEffortRepushCoverage() async {
    try {
      await _repushCoverage();
    } catch (_) {}
  }

  Future<void> _enqueueVisibility(Future<void> Function() operation) {
    final runImmediately = _pendingVisibilityOperations == 0;
    _pendingVisibilityOperations += 1;
    final operationFuture = runImmediately
        ? Future<void>.sync(operation)
        : _visibilityTail.then<void>((_) => operation());

    Future<void> settle() async {
      try {
        await operationFuture;
      } catch (_) {
        // Visibility is display-only; a failed operation must not stall the
        // queue or prevent detach from restoring the native defaults.
      } finally {
        _pendingVisibilityOperations -= 1;
      }
    }

    final completion = settle();
    _visibilityTail = completion;
    return completion;
  }
}
