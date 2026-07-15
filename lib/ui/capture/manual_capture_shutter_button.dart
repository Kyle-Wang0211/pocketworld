import 'package:flutter/material.dart';

/// Capture-front-end shutter with no background-work state.
///
/// Once [enabled], every tap is forwarded immediately. JPEG publication,
/// durable queue depth, reconstruction work, and thermal state never replace
/// this control with a loader or disable it. The capture session assigns each
/// tap its own job identity and owns all asynchronous completion work.
class ManualCaptureShutterButton extends StatelessWidget {
  const ManualCaptureShutterButton({
    required this.enabled,
    required this.onTap,
    super.key,
  });

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: enabled,
      label: '拍照',
      child: Opacity(
        opacity: enabled ? 1.0 : 0.4,
        child: GestureDetector(
          onTap: enabled ? onTap : null,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 4),
            ),
            child: const Padding(
              padding: EdgeInsets.all(5),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
