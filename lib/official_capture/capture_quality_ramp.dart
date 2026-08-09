// capture_quality_ramp.dart — 拍摄期 AR 点云的质量色标(纯显示,不碰数据)。
//
// [P1 SATURATING-RAMP 2026-07-28] 复刻 RealityScan 的采集期着色读感。
//
// 病因(实测+取证):旧实现是三段硬阈值(≥5 绿 / ≥3 黄 / 2 红)。我方 cap7
// 实测 track 长度中位 2、均值 2.905、**62.4% 是 2 视**——三个色阶被全部塞进
// 分布最密最陡的 2-5 区间,量化台阶宽度 ≈ 逐点采样噪声幅度,于是噪声被 1:1
// 翻译成颜色 → 屏幕上是红黄绿椒盐雪花,用户读不出"哪块该补拍"。
//
// RS 为什么读起来是分区(像素取证,官方商品页素材):RS **也是逐点上色**
// (官方措辞 "evaluates the camera coverage of each tie point"),它的地面同样
// 是雪花(64px 滞后相关仅 +0.08);差别在**饱和**——主体上 67% 的点是绿的、
// 红仅 8.9%,因为绕拍主体的点被 30+ 相机看到,**全部撞到色标顶端**,逐点噪声
// 被饱和数学地吃掉。
//
// 因此本实现照抄这个机制:**连续渐变 + 低饱和点**。
//   t = clamp((track − floor) / (satAt − floor), 0, 1)   → 红→黄→绿 连续插值
//   track ≥ satAt 一律纯绿,再多也不变(饱和,消除高端抖动)
// 连续插值同时消掉了硬台阶:相邻点 track 差 1 只产生一点色差,而不是整档跳变。
//
// ⚠️ 这是**显示层**改动:点集、几何、交付、导出全不受影响。
// ⚠️ satAt 是唯一需要肉眼调的旋钮 —— 调低 = 更多点饱和成绿(画面更"干净"、
//    但对欠拍区更不敏感);调高 = 分辨力更强、但更容易回到雪花。

/// 三段锚色沿用旧实现的取值(用户已看惯的红/黄/绿),只把"跳变"改成"渐变"。
class CaptureQualityRamp {
  const CaptureQualityRamp({required this.floor, required this.satAt});

  /// 色标下沿:track ≤ floor → 纯红。2 视是我方点云的众数,定为下沿。
  final int floor;

  /// 饱和点:track ≥ satAt → 纯绿,再高不变。
  final int satAt;

  /// 返回 (r, g, b)。纯函数,便于契约测试。
  (int, int, int) colorFor(int trackLength) {
    // 契约优先:达到饱和点即纯绿(退化配置 floor==satAt 下也成立)。
    if (trackLength >= satAt) return (56, 220, 110);
    final span = (satAt - floor).clamp(1, 1 << 20);
    var t = (trackLength - floor) / span;
    if (t.isNaN) t = 0;
    t = t.clamp(0.0, 1.0);
    // 红 (255,82,47) → 黄 (255,210,45) → 绿 (56,220,110)
    if (t <= 0.5) {
      final u = t * 2;
      return (
        _lerp(255, 255, u),
        _lerp(82, 210, u),
        _lerp(47, 45, u),
      );
    }
    final u = (t - 0.5) * 2;
    return (
      _lerp(255, 56, u),
      _lerp(210, 220, u),
      _lerp(45, 110, u),
    );
  }

  static int _lerp(int a, int b, double u) =>
      (a + (b - a) * u).round().clamp(0, 255);
}

/// 出货档:2 视=纯红,5 视及以上=纯绿(中间连续)。
///
/// [T_SAT 8→5 2026-08-05] 三方独立证据一致落在 5,故下调:
///  ① **Pix4D 官方**(同构的红→绿覆盖热图,唯一带数字的行业锚)逐字:
///     "the overlap should be in green, i.e. each pixel should be visible in
///     **more than 5 images**"。
///  ② **我方实测**(146 帧真机采集 12.5 万点,E3 A 臂 points3D):track length
///     p50=2 / p75=3 / **p90=5** / p95=6 / p99=10 / max=28。
///  ③ **RC 逐点法医**(586,258 点原生 Bundler 直方图):**p90 同样是 5**。
///
/// 为什么原来的 8 太高:到 8 视的点只占 **1.9%**,到 10 视只占 0.9% ——
/// 饱和段实际上永远够不着,屏幕上不可能出现"这块搞定了"的纯绿区。
/// satAt=5 让 top ~10% 的点饱和成绿,才形成 RS 那种"主体绿 / 外围杂色"的对比。
///
/// ⚠️ 不要上调到 10–12:那是从"RS 主体被 30+ 相机看到"反推的,而那个 30+ 本身
/// 是像素观察推断,**官方与民间均无公开阈值**(两轮穷尽检索确认)。按我方分布,
/// 10–12 会让 99% 的点都不饱和,比 8 更糟。
///
/// ⚠️ 已知机制缺陷(暂不修):纯 track length 会被**同角度连拍虚涨**——Epic 官方
/// FAQ 措辞是 "from various good **angles**"、"angles **in between** previous
/// shots",Apple Object Capture 专利 US12394145B2 则把它实现成"入射角接近已有
/// 视角则贡献打折"。长期应考虑角度加权;该专利需先过 FTO,不得照抄公式。
const kCaptureQualityRamp = CaptureQualityRamp(floor: 2, satAt: 5);
