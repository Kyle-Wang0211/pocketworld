// Cross-platform model-download progress UI.
//
// Target install path:
//   pocketworld_flutter/lib/capture/ui/model_download_dialog.dart
//
// Shown as a modal barrier when the user opens the capture page and the
// tier-matched DA3 mlpackage hasn't been pulled to the device yet. Same
// widget runs on iOS / Android / Web / HarmonyOS — only the underlying
// MethodChannel changes per platform.
//
// Usage from capture entry-point:
//   final result = await ModelDownloadDialog.run(context);
//   if (result == null) { Navigator.pop(context); return; }    // cancelled
//   // result.localPath is now safe to hand to the native depth wrapper.
//
// UX rationale
// ------------
// • One-time experience: only the first capture per app install ever
//   sees this dialog. After that, the cached fast-path of
//   `ModelLoader.localPathIfCached` returns non-null and we skip
//   straight into the dome.
// • No "ready / cancel / retry" buttons during fetch — ODR requests on
//   iOS are not cleanly cancellable mid-stream and trying to fake it
//   leaks the underlying NSBundleResourceRequest. Just show progress and
//   a single "Cancel" that bails out of the dialog (the underlying
//   request keeps running silently; next attempt sees the resumed cache).
// • LinearProgressIndicator (not CircularProgressIndicator) because the
//   download is hundreds of MB on cellular — users want to see a bar so they
//   can decide to step away.

import 'dart:async';

import 'package:flutter/material.dart';

import '../model_loader.dart';

class ModelDownloadDialog extends StatefulWidget {
  const ModelDownloadDialog._({required this.tagLabel});

  final String tagLabel;

  /// Imperative entry. Pushes the dialog as a modal route, kicks off
  /// `ModelLoader.instance.ensureReady()`, returns the result (or null
  /// if the user cancelled).
  ///
  /// Caller is responsible for handling a null return (typically pops
  /// the capture page and shows a snackbar).
  static Future<ModelReadyResult?> run(BuildContext context) async {
    // Decide what tag we're fetching so the dialog can label it.
    // Don't await ensureReady here — let the dialog drive the call.
    final tier = await ModelLoader.instance.deviceTier();
    final label = _labelFor(tier);

    if (!context.mounted) return null;

    return showDialog<ModelReadyResult>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => ModelDownloadDialog._(tagLabel: label),
    );
  }

  static String _labelFor(ModelTag tag) {
    switch (tag) {
      case ModelTag.tierLow:
        // DA3-BASE K30 pose-conditioned CoreML bundle.
        return '~350 MB';
      case ModelTag.tierHigh:
        // DA3-BASE K40 pose-conditioned CoreML bundle.
        return '~500 MB';
    }
  }

  @override
  State<ModelDownloadDialog> createState() => _ModelDownloadDialogState();
}

class _ModelDownloadDialogState extends State<ModelDownloadDialog> {
  double _fraction = 0.0;
  String _statusLine = 'Preparing…';
  Object? _error;
  StreamSubscription<ModelDownloadProgress>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = ModelLoader.instance.progress.listen(
      (p) {
        if (!mounted) return;
        setState(() {
          _fraction = p.fraction;
          // Show MB-style status as a percentage; absolute bytes are
          // pulled from the native side only when the request can
          // expose them (NSBundleResourceRequest progress reports
          // KVO on fractionCompleted; bytesTransferred is not always
          // populated, so we just show percent).
          _statusLine =
              'Downloading model… ${(p.fraction * 100).toStringAsFixed(0)}%';
        });
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _error = e;
          _statusLine = 'Download failed';
        });
      },
    );
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final result = await ModelLoader.instance.ensureReady();
      if (!mounted) return;
      // Briefly show 100% before dismissing so the bar doesn't snap
      // to nothing.
      setState(() {
        _fraction = 1.0;
        _statusLine = 'Ready';
      });
      // Tiny settle so the user actually sees the "Ready" state.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (mounted) Navigator.of(context).pop(result);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _statusLine = 'Download failed';
        });
      }
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasError = _error != null;
    return AlertDialog(
      title: const Text('First-time setup'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'PocketWorld needs to download the depth model '
            '(${widget.tagLabel}) for your device. This is a one-time '
            'download — future captures launch instantly.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          LinearProgressIndicator(
            value: hasError ? null : _fraction,
            minHeight: 6,
          ),
          const SizedBox(height: 8),
          Text(
            hasError ? 'Tap retry to try again' : _statusLine,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        if (hasError)
          TextButton(
            onPressed: () {
              setState(() {
                _error = null;
                _fraction = 0.0;
                _statusLine = 'Preparing…';
              });
              unawaited(_start());
            },
            child: const Text('Retry'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
