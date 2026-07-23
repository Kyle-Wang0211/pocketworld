import 'package:flutter/material.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';

import 'design_system.dart';

enum CaptureRouteChoice { selfDeveloped, official }

/// Route chooser shown before entering capture.
///
/// This is deliberately the only shared UI in the two capture stacks. Once a
/// route is selected, each stack owns its page, state and platform channels.
class CapturePipelineChooser extends StatelessWidget {
  const CapturePipelineChooser({super.key, required this.onSelected});

  final ValueChanged<CaptureRouteChoice> onSelected;

  static const LiquidGlassSettings glassSettings = LiquidGlassSettings(
    thickness: 20,
    blur: 4,
    glassColor: Color(0x08FFFFFF),
    refractiveIndex: 1.20,
    lightIntensity: 1.0,
    saturation: 1.0,
  );

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: LiquidGlassLayer(
        settings: glassSettings,
        child: LiquidGlass(
          shape: const LiquidRoundedSuperellipse(borderRadius: 28),
          glassContainsChild: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.20),
                width: 0.8,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(4, 0, 4, 14),
                  child: Text(
                    '选择拍摄路线',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: _RouteTile(
                        key: const ValueKey('capture-route-self-developed'),
                        title: '自研',
                        subtitle: '当前产品基线',
                        icon: Icons.auto_awesome_rounded,
                        onTap: () =>
                            onSelected(CaptureRouteChoice.selfDeveloped),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _RouteTile(
                        key: const ValueKey('capture-route-official'),
                        title: '官方',
                        subtitle: '官方对齐路线',
                        icon: Icons.verified_outlined,
                        onTap: () => onSelected(CaptureRouteChoice.official),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RouteTile extends StatelessWidget {
  const _RouteTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 16, 12, 15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: AetherColors.primary.withValues(alpha: 0.88),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(icon, color: Colors.white, size: 21),
              ),
              const SizedBox(height: 18),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.70),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
