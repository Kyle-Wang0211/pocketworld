import 'package:flutter/material.dart';

const captureGlassTint = Color(0x08FFFFFF);
const captureGlassActive = Color(0xFFFFC53D);
const captureGlassInactive = Color(0x99FFFFFF);

/// The display-only visibility controls shown over the native capture preview.
class CaptureOverlayControls extends StatelessWidget {
  static const panelKey = ValueKey<String>('capture_glass_panel');
  static const photoKey = ValueKey<String>('capture_photo_cards_toggle');
  static const pointsKey = ValueKey<String>('capture_coverage_points_toggle');

  final bool photoCardsVisible;
  final bool coveragePointsVisible;
  final ValueChanged<bool> onPhotoCardsChanged;
  final ValueChanged<bool> onCoveragePointsChanged;

  const CaptureOverlayControls({
    super.key,
    required this.photoCardsVisible,
    required this.coveragePointsVisible,
    required this.onPhotoCardsChanged,
    required this.onCoveragePointsChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      key: panelKey,
      width: 176,
      height: 52,
      decoration: BoxDecoration(
        color: captureGlassTint,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0x3DFFFFFF)),
      ),
      child: Stack(
        fit: StackFit.expand,
        alignment: Alignment.center,
        children: [
          Row(
            children: [
              _CaptureToggle(
                key: photoKey,
                label: '显示照片卡片',
                value: photoCardsVisible,
                onChanged: onPhotoCardsChanged,
                child: Icon(
                  Icons.photo_outlined,
                  size: 27,
                  color: photoCardsVisible
                      ? captureGlassActive
                      : captureGlassInactive,
                ),
              ),
              _CaptureToggle(
                key: pointsKey,
                label: '显示覆盖点',
                value: coveragePointsVisible,
                onChanged: onCoveragePointsChanged,
                child: _CoverageGridIcon(
                  color: coveragePointsVisible
                      ? captureGlassActive
                      : captureGlassInactive,
                ),
              ),
            ],
          ),
          const IgnorePointer(
            child: Center(
              child: SizedBox(
                width: 1,
                height: 24,
                child: ColoredBox(color: Color(0x33FFFFFF)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CaptureToggle extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final Widget child;

  const _CaptureToggle({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    void toggle() => onChanged(!value);

    return Semantics(
      container: true,
      label: label,
      button: true,
      toggled: value,
      onTap: toggle,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: toggle,
        child: SizedBox(width: 88, height: 52, child: Center(child: child)),
      ),
    );
  }
}

class _CoverageGridIcon extends StatelessWidget {
  final Color color;

  const _CoverageGridIcon({required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 27,
      height: 27,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: List.generate(
          3,
          (_) => Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(
              3,
              (_) => SizedBox.square(
                dimension: 5,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Reports this child's global logical rectangle after layout changes.
///
/// Measurement is registered for each rendered frame, but an unchanged [Rect]
/// is never emitted twice. Registering the next callback does not itself
/// schedule a frame.
class CaptureGlassRectReporter extends StatefulWidget {
  final ValueChanged<Rect> onRectChanged;
  final Widget child;

  const CaptureGlassRectReporter({
    super.key,
    required this.onRectChanged,
    required this.child,
  });

  @override
  State<CaptureGlassRectReporter> createState() =>
      _CaptureGlassRectReporterState();
}

class _CaptureGlassRectReporterState extends State<CaptureGlassRectReporter> {
  Rect? _lastRect;
  bool _measurementScheduled = false;

  @override
  void initState() {
    super.initState();
    _scheduleMeasurement();
  }

  void _scheduleMeasurement() {
    if (_measurementScheduled) return;
    _measurementScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measurementScheduled = false;
      if (!mounted) return;

      final renderObject = context.findRenderObject();
      if (renderObject is RenderBox && renderObject.hasSize) {
        final origin = renderObject.localToGlobal(Offset.zero);
        final rect = origin & renderObject.size;
        if (rect != _lastRect) {
          _lastRect = rect;
          widget.onRectChanged(rect);
        }
      }

      _scheduleMeasurement();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
