// CubeTransitionDemo — a pure-Flutter "fake cube" page transition.
//
// No 3D engine: the two pages (登录 / 个人) are the front + right faces of a
// cube, folded around their shared vertical edge with a perspective Matrix4.
// Swipe horizontally (or tap 继续) to rotate the cube between faces; the face
// turning away darkens to sell the depth; release snaps to the nearest face.
//
// Palette is strictly black / white / gray. This is a self-contained design
// study wired as the temporary app home — revert main.dart to restore the
// real auth flow.
import 'package:flutter/material.dart';

class CubeTransitionDemo extends StatefulWidget {
  const CubeTransitionDemo({super.key});

  @override
  State<CubeTransitionDemo> createState() => _CubeTransitionDemoState();
}

class _CubeTransitionDemoState extends State<CubeTransitionDemo>
    with SingleTickerProviderStateMixin {
  // ── palette ──────────────────────────────────────────────────────────
  static const _stage = Color(0xFF0B0B0C); // near-black backdrop
  static const _faceLogin = Color(0xFFFFFFFF); // white
  static const _facePersonal = Color(0xFFF3F3F4); // faint gray (distinct face)
  static const _ink = Color(0xFF0A0A0A);
  static const _inkSoft = Color(0xFF9A9A9F);
  static const _line = Color(0xFFE7E7EA);

  late final AnimationController _ctrl;
  Animation<double>? _snap;
  double _t = 0; // 0 = login front, 1 = personal front

  @override
  void initState() {
    super.initState();
    _ctrl =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 480),
        )..addListener(() {
          final s = _snap;
          if (s != null) setState(() => _t = s.value);
        });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _snapTo(double target) {
    _snap = Tween<double>(
      begin: _t,
      end: target,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    _ctrl.forward(from: 0);
  }

  void _onDragUpdate(DragUpdateDetails d, double width) {
    _ctrl.stop();
    // swipe left (dx < 0) advances toward the personal face.
    setState(() => _t = (_t - d.primaryDelta! / width).clamp(0.0, 1.0));
  }

  void _onDragEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0; // px/s; <0 = flung left
    if (v < -350) {
      _snapTo(1);
    } else if (v > 350) {
      _snapTo(0);
    } else {
      _snapTo(_t >= 0.5 ? 1 : 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _stage,
      body: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          final loginOnTop = _t < 0.5;
          final faces = <Widget>[
            _cubeFace(isLogin: false, child: _personalFace()),
            _cubeFace(isLogin: true, child: _loginFace()),
          ];
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (d) => _onDragUpdate(d, w),
            onHorizontalDragEnd: _onDragEnd,
            child: Stack(
              fit: StackFit.expand, // fill the screen — all children are
              // Positioned, so without this the Stack collapses to 0×0 and
              // you only see the near-black stage (the "black screen" bug).
              children: [
                // paint the more-front face last (on top)
                if (loginOnTop) ...faces else ...faces.reversed,
                _foldSeam(w),
                _pageDots(),
                _swipeHint(),
              ],
            ),
          );
        },
      ),
    );
  }

  // ── the cube ─────────────────────────────────────────────────────────
  /// One face of the cube. Login pivots on its right edge, personal on its
  /// left edge; both share that vertical edge so the pair folds like a cube.
  Widget _cubeFace({required bool isLogin, required Widget child}) {
    final angle = isLogin
        ? -1.5707963 *
              _t // 0 → -90° as we turn away
        : 1.5707963 * (1 - _t); // +90° → 0° as it comes forward
    // how far this face is turned away from camera (0 flat .. 1 edge-on)
    final turn = isLogin ? _t : (1 - _t);
    final m = Matrix4.identity()
      ..setEntry(3, 2, 0.0013) // perspective
      ..rotateY(angle);
    return Positioned.fill(
      child: Transform(
        alignment: isLogin ? Alignment.centerRight : Alignment.centerLeft,
        transform: m,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(30),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(
                  color: isLogin ? _faceLogin : _facePersonal,
                  child: child,
                ),
                // darken the face as it turns away → fake lighting / depth
                IgnorePointer(
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: 0.62 * turn),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// A soft shadow down the shared edge while mid-fold — sells the crease.
  Widget _foldSeam(double w) {
    final intensity = (1 - (2 * _t - 1).abs()); // peaks at t=0.5
    if (intensity < 0.02) return const SizedBox.shrink();
    return Positioned(
      left: w / 2 - 24,
      top: 14,
      bottom: 14,
      width: 48,
      child: IgnorePointer(
        child: Opacity(
          opacity: intensity * 0.5,
          child: const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.transparent,
                  Colors.black54,
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _pageDots() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [_dot(1 - _t), const SizedBox(width: 7), _dot(_t)],
          ),
        ),
      ),
    );
  }

  Widget _dot(double on) => Container(
    width: 6 + 10 * on,
    height: 6,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(3),
      color: Color.lerp(Colors.white24, Colors.white, on),
    ),
  );

  Widget _swipeHint() {
    final o = (1 - _t * 2).clamp(0.0, 1.0); // visible on the login face
    if (o < 0.02) return const SizedBox.shrink();
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        child: Opacity(
          opacity: o * 0.6,
          child: const Padding(
            padding: EdgeInsets.only(bottom: 18),
            child: Text(
              '← 滑动进入空间 →',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _inkSoft,
                fontSize: 12,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── face 1: 登录 ──────────────────────────────────────────────────────
  Widget _loginFace() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Spacer(flex: 5),
            // minimal cube mark
            Center(
              child: Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: _ink,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: const Icon(
                  Icons.view_in_ar_outlined,
                  color: Colors.white,
                  size: 28,
                ),
              ),
            ),
            const SizedBox(height: 22),
            const Text(
              'PocketWorld',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _ink,
                fontSize: 30,
                fontWeight: FontWeight.w800,
                letterSpacing: -1.0,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '3D 空间，人人可造',
              textAlign: TextAlign.center,
              style: TextStyle(color: _inkSoft, fontSize: 14),
            ),
            const Spacer(flex: 5),
            _field('邮箱 / 手机号'),
            const SizedBox(height: 12),
            _primaryButton('继续', onTap: () => _snapTo(1)),
            const SizedBox(height: 22),
            Row(
              children: [
                const Expanded(child: Divider(color: _line)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    '其他方式',
                    style: TextStyle(color: _inkSoft, fontSize: 12),
                  ),
                ),
                const Expanded(child: Divider(color: _line)),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _ovalSocial(Icons.apple),
                const SizedBox(width: 14),
                _ovalSocial(Icons.g_mobiledata_rounded),
              ],
            ),
            const Spacer(flex: 6),
          ],
        ),
      ),
    );
  }

  Widget _field(String hint) => Container(
    height: 54,
    alignment: Alignment.centerLeft,
    padding: const EdgeInsets.symmetric(horizontal: 18),
    decoration: BoxDecoration(
      color: const Color(0xFFF5F5F6),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: _line),
    ),
    child: Text(hint, style: const TextStyle(color: _inkSoft, fontSize: 15)),
  );

  Widget _primaryButton(String label, {required VoidCallback onTap}) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          height: 54,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _ink,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );

  Widget _ovalSocial(IconData icon) => Container(
    width: 56,
    height: 48,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: _line),
    ),
    child: Icon(icon, color: _ink, size: 26),
  );

  // ── face 2: 个人 ──────────────────────────────────────────────────────
  Widget _personalFace() {
    return SafeArea(
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 12),
                Row(
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: const BoxDecoration(
                        color: Color(0xFFE2E2E5),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.person_rounded,
                        color: Color(0xFF9A9A9F),
                        size: 30,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        Text(
                          'Kyle',
                          style: TextStyle(
                            color: _ink,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          '作品 12 · 浏览 1.2k',
                          style: TextStyle(color: _inkSoft, fontSize: 13),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 26),
                const Text(
                  '我的空间',
                  style: TextStyle(
                    color: _ink,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: GridView.count(
                    crossAxisCount: 2,
                    mainAxisSpacing: 14,
                    crossAxisSpacing: 14,
                    childAspectRatio: 0.82,
                    physics: const NeverScrollableScrollPhysics(),
                    children: List.generate(4, (i) => _workCard(i)),
                  ),
                ),
              ],
            ),
          ),
          // the black "+" capture sphere — consistent with V1
          Positioned(
            right: 22,
            bottom: 24,
            child: Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: _ink,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.22),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: const Icon(
                Icons.add_rounded,
                color: Colors.white,
                size: 30,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _workCard(int i) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xFFEAEAEC),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Center(
      child: Icon(
        Icons.view_in_ar_outlined,
        color: const Color(0xFFB6B6BB),
        size: 34,
      ),
    ),
  );
}
