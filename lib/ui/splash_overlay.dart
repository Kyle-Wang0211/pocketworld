// PocketWorld Flutter-side splash overlay.
//
// iOS LaunchScreen.storyboard is necessarily static. Once Flutter owns the
// first frame, this overlay covers renderer warm-up with a realtime Canvas
// animation and reveals the live app beneath it.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'splash_solving_orb.dart';

enum SplashExitStyle { fade, directLineDoor }

class AetherSplashOverlay extends StatefulWidget {
  const AetherSplashOverlay({
    super.key,
    required this.visible,
    this.progressMessage,
    this.exitStyle = SplashExitStyle.fade,
  });

  final bool visible;
  final SplashExitStyle exitStyle;

  /// Retained for compatibility with existing boot call sites.
  ///
  /// The approved minimal splash deliberately renders no progress copy.
  final String? progressMessage;

  @override
  State<AetherSplashOverlay> createState() => _AetherSplashOverlayState();
}

class _AetherSplashOverlayState extends State<AetherSplashOverlay>
    with TickerProviderStateMixin {
  static const _lineDuration = Duration(milliseconds: 500);
  static const _lineHoldDuration = Duration(milliseconds: 110);
  static const _doorDuration = Duration(milliseconds: 680);
  static const _directExitDuration = Duration(milliseconds: 1290);

  late final AnimationController _fadeController;
  late final AnimationController _directController;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
      value: widget.visible ? 1 : 0,
    )..addStatusListener(_handleFadeStatus);
    _directController = AnimationController(
      vsync: this,
      duration: _directExitDuration,
      value: widget.visible ? 0 : 1,
    )..addStatusListener(_handleDirectStatus);
  }

  void _handleFadeStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && mounted) {
      _finishExitIfHidden();
    }
  }

  void _handleDirectStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) {
      _finishExitIfHidden();
    }
  }

  void _finishExitIfHidden() {
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.visible) return;
      final finished = switch (widget.exitStyle) {
        SplashExitStyle.fade => _fadeController.isDismissed,
        SplashExitStyle.directLineDoor => _directController.isCompleted,
      };
      if (finished) {
        SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.dark);
      }
    });
  }

  @override
  void didUpdateWidget(covariant AetherSplashOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.exitStyle != oldWidget.exitStyle) {
      if (widget.visible) {
        _fadeController.value = 1;
        _directController.value = 0;
      } else if (widget.exitStyle == SplashExitStyle.directLineDoor) {
        _directController.value = 1;
      } else {
        _fadeController.value = 0;
      }
    }

    if (widget.visible == oldWidget.visible) return;
    if (widget.visible) {
      if (widget.exitStyle == SplashExitStyle.directLineDoor) {
        _directController.value = 0;
      } else {
        _fadeController.forward();
      }
      return;
    }

    if (widget.exitStyle == SplashExitStyle.directLineDoor) {
      final reducedMotion =
          MediaQuery.maybeOf(context)?.disableAnimations ?? false;
      if (reducedMotion) {
        _directController.value = 1;
      } else {
        _directController.forward(from: 0);
      }
    } else {
      _fadeController.reverse();
    }
  }

  @override
  void dispose() {
    final exitIncomplete = switch (widget.exitStyle) {
      SplashExitStyle.fade => !_fadeController.isDismissed,
      SplashExitStyle.directLineDoor => !_directController.isCompleted,
    };
    if (exitIncomplete) {
      SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.dark);
    }
    _fadeController.dispose();
    _directController.dispose();
    super.dispose();
  }

  bool get _exitFinished => switch (widget.exitStyle) {
    SplashExitStyle.fade => _fadeController.isDismissed,
    SplashExitStyle.directLineDoor => _directController.isCompleted,
  };

  @override
  Widget build(BuildContext context) {
    if (!widget.visible && _exitFinished) {
      return const SizedBox.shrink();
    }

    if (widget.exitStyle == SplashExitStyle.directLineDoor) {
      return _buildDirectLineDoor(context);
    }
    return _buildFade();
  }

  Widget _buildFade() {
    return IgnorePointer(
      ignoring: !widget.visible,
      child: FadeTransition(
        opacity: _fadeController,
        child: const AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle.light,
          child: ColoredBox(
            key: ValueKey('splash-background'),
            color: Colors.black,
            child: Center(
              child: SplashSolvingOrb(
                key: ValueKey('splash-solving-orb'),
                size: 128,
                speed: 0.8,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDirectLineDoor(BuildContext context) {
    final devicePixelRatio = View.of(context).devicePixelRatio;
    return IgnorePointer(
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: KeyedSubtree(
          key: const ValueKey('splash-background'),
          child: AnimatedBuilder(
            animation: _directController,
            builder: (context, _) {
              final elapsed =
                  _directController.value * _directExitDuration.inMilliseconds;
              final lineProgress = Curves.easeInOutCubic.transform(
                (elapsed / _lineDuration.inMilliseconds).clamp(0.0, 1.0),
              );
              final doorProgress = Curves.easeInOutCubic.transform(
                ((elapsed -
                            _lineDuration.inMilliseconds -
                            _lineHoldDuration.inMilliseconds) /
                        _doorDuration.inMilliseconds)
                    .clamp(0.0, 1.0),
              );
              final doorStartsAt =
                  _lineDuration.inMilliseconds +
                  _lineHoldDuration.inMilliseconds;

              return Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(
                    key: const ValueKey('splash-door-painter'),
                    painter: SplashDoorPainter(
                      openProgress: doorProgress,
                      devicePixelRatio: devicePixelRatio,
                      showSeam: elapsed >= doorStartsAt,
                    ),
                  ),
                  if (elapsed < doorStartsAt)
                    SplashDirectLineField(
                      morphProgress: lineProgress,
                      orbSize: 128,
                      speed: 0.8,
                      color: Colors.white,
                      animate: widget.visible,
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

@immutable
class SplashDoorGeometry {
  const SplashDoorGeometry({
    required this.leftPanel,
    required this.rightPanel,
    required this.leftSeam,
    required this.rightSeam,
  });

  final Rect leftPanel;
  final Rect rightPanel;
  final Rect leftSeam;
  final Rect rightSeam;
}

class SplashDoorPainter extends CustomPainter {
  SplashDoorPainter({
    required this.openProgress,
    required this.devicePixelRatio,
    this.showSeam = true,
  }) : assert(openProgress >= 0 && openProgress <= 1),
       assert(devicePixelRatio > 0);

  final double openProgress;
  final double devicePixelRatio;
  final bool showSeam;

  SplashDoorGeometry geometryFor(Size size) {
    final center = size.width / 2;
    final travel = center * openProgress;
    final seamWidth = 1 / devicePixelRatio;
    final leftPanel = Rect.fromLTRB(-travel, 0, center - travel, size.height);
    final rightPanel = Rect.fromLTRB(
      center + travel,
      0,
      size.width + travel,
      size.height,
    );
    return SplashDoorGeometry(
      leftPanel: leftPanel,
      rightPanel: rightPanel,
      leftSeam: Rect.fromLTWH(
        leftPanel.right - seamWidth,
        0,
        seamWidth,
        size.height,
      ),
      rightSeam: Rect.fromLTWH(rightPanel.left, 0, seamWidth, size.height),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final geometry = geometryFor(size);
    final paint = Paint()
      ..isAntiAlias = false
      ..color = Colors.black;
    canvas.drawRect(geometry.leftPanel, paint);
    canvas.drawRect(geometry.rightPanel, paint);
    if (showSeam) {
      paint.color = Colors.white;
      canvas.drawRect(geometry.leftSeam, paint);
      canvas.drawRect(geometry.rightSeam, paint);
    }
  }

  @override
  bool shouldRepaint(covariant SplashDoorPainter oldDelegate) {
    return oldDelegate.openProgress != openProgress ||
        oldDelegate.devicePixelRatio != devicePixelRatio ||
        oldDelegate.showSeam != showSeam;
  }
}
