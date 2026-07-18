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

  CaptureOverlayController({
    required NativeOverlayInvoker invokeNative,
    required Future<void> Function() repushCoverage,
  }) : _invokeNative = invokeNative,
       _repushCoverage = repushCoverage;

  bool get photoCardsVisible => _photoCardsVisible;
  bool get coveragePointsVisible => _coveragePointsVisible;

  Future<void> setPhotoCardsVisible(bool visible) async {
    if (_photoCardsVisible == visible) return;

    _photoCardsVisible = visible;
    notifyListeners();
    await _bestEffortNative('setPhotoCardsVisible', <String, Object?>{
      'visible': visible,
    });
  }

  Future<void> setCoveragePointsVisible(bool visible) async {
    if (_coveragePointsVisible == visible) return;

    _coveragePointsVisible = visible;
    notifyListeners();
    await _bestEffortNative('setFeaturePointsVisible', <String, Object?>{
      'visible': visible,
    });
    if (visible) await _bestEffortRepushCoverage();
  }

  Future<void> reportGlassRect(Rect rect) async {
    if (!_isValidGlassRect(rect) || _lastGlassRect == rect) return;

    _lastGlassRect = rect;
    final shouldEnable = !_glassEnableSent;
    _glassEnableSent = true;

    await _bestEffortNative('setCaptureGlassRect', <String, Object?>{
      'x': rect.left,
      'y': rect.top,
      'width': rect.width,
      'height': rect.height,
    });
    if (shouldEnable) {
      await _bestEffortNative('setCaptureGlassEnabled', <String, Object?>{
        'enabled': true,
      });
    }
  }

  Future<void> syncNativeVisibility() async {
    await _bestEffortNative('setPhotoCardsVisible', <String, Object?>{
      'visible': _photoCardsVisible,
    });
    await _bestEffortNative('setFeaturePointsVisible', <String, Object?>{
      'visible': _coveragePointsVisible,
    });
    if (_coveragePointsVisible) await _bestEffortRepushCoverage();
  }

  Future<void> detach() async {
    if (_detached) return;
    _detached = true;
    await _bestEffortNative('setCaptureGlassEnabled', <String, Object?>{
      'enabled': false,
    });
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
}
