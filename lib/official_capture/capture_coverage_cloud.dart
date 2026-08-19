// capture_coverage_cloud.dart — RS-style capture-coverage cloud POLICY.
//
// The product semantic (per RealityScan's capture UX): the colored cloud is
// what the algorithm has RECEIVED — it must be empty before the first
// shutter, grow only when photos are committed, and color each point by how
// many captured photos actually saw it (1 ≈ red/orange, 2-3 ≈ yellow,
// ≥5 ≈ green). Tracker persistence alone must never light anything up.
//
// Per the algorithm-executor boundary (ARFrameSaveSpec.dartOwns: "coverage
// logic"), ALL of that policy lives here in Dart — shared verbatim across
// iOS/Android/HarmonyOS. Platform executors only:
//   • feed VIO points (ARPose.previewPoints — already crossing on the pose
//     stream on iOS; ARCore/AREngine equivalents feed the same call), and
//   • render the packed xyz+rgb this class emits (iOS: the dumb
//     `setCoveragePointCloud` SceneKit executor).
//
// Data flow:
//   poseStream → [ingestPose]  — voxel-hash VIO points (position upkeep)
//   sfmFrameStream (per committed shutter, the SAME frame-exact
//   pose+intrinsics feed that drives streaming SfM) → [markCapture]
//   — frustum-test every voxel, bump its photo-coverage count → [packed]
//   → platform renderer.
//   SfM worker 的 live_parallax 事件(真实三角化角,route B,见
//   true_parallax.dart)→ [applyTrueParallax] — 体素级真值注入,压黄/
//   判黄改用真值,视锥近似(route A)只在真值未到达时兜底。

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart' show Vector3;
import 'package:vector_math/vector_math_64.dart' as vm;

import '../official_dome/ar_pose.dart' show ARPose, SfmFrameFeed;
import 'photo_card_state.dart' show medianOf;
import 'true_parallax.dart'
    show coverageVoxelKeyFor, kCaptureParallaxMinDeg, kCoverageVoxelSizeM;

/// Packed render payload for the platform's dumb point renderer.
class CoverageCloudPacked {
  const CoverageCloudPacked(this.xyz, this.rgb);
  final Float32List xyz; // 3 floats per point, world space
  final Uint8List rgb; // 3 bytes per point
  int get count => xyz.length ~/ 3;
}

class _CoverageVoxel {
  _CoverageVoxel(this.position);
  Vector3 position; // refreshed by the tracker (ingestPose)
  int photoCoverage = 0; // bumped by markCapture — THE product signal
  int seen = 1; // tracker persistence, pruning tie-breaker only

  /// 首次被照片拍到时的视线方向(单位向量,相机中心→体素,世界系)。
  Vector3? firstViewDir;

  /// 历次观测视线与首观测视线的最大夹角(度)——视锥近似视差(route A)。
  /// ⚠️已降级为**次要兜底信号**:真机遥测实锤它过松两个数量级(5997 体素
  /// 仅 1 starved / 98% 绿,而最终云 40.3% 点真实三角化角 <8°)——视锥
  /// 命中只证明"相机看向了这里",不证明特征点被真实双视角观测。体素
  /// 压黄一律优先用 worker 算的真实三角化角([CaptureCoverageCloud
  /// .applyTrueParallax] 注入),本值只在真值未到达时兜底;**帧卡片判黄
  /// 则完全不用它**(真值唯一,见 photo_card_state.frameLowParallaxTrue)。
  /// 视差背景一句话:"双墙"真身=低视差深度噪声壳,视差角是厚/薄的判别因子。
  double maxParallaxDeg = 0;
}

class CaptureCoverageCloud {
  CaptureCoverageCloud({
    this.voxelSizeM = kCoverageVoxelSizeM,
    this.maxVoxels = 65000,
    this.coverageSaturation = 5,
    this.parallaxMinDeg = kCaptureParallaxMinDeg,
  });

  /// Single-scale voxel edge — coarse enough to stay cheap, fine enough to
  /// read as a surface fog (RS-like density).
  final double voxelSizeM;

  /// 体素总量上限。6000 → 65000(2026-07-11 案②修复 + 用户签决提额):
  /// 46 号采集 67/93 张时 6000 个体素全部 covered,旧淘汰序
  /// (photoCoverage DESC)让新区体素插入即被挤出,后 26 张零新覆盖点。
  /// 空间是立体的 —— 一个书柜就吃 ~9.6m²,覆盖一个房间按 100m² 起步:
  /// 4cm 体素 ≈ 62,500 个 → 上限定 65,000。
  ///
  /// 成本对账(tool/coverage_eviction_check.dart 65k 满载实测,host VM):
  ///   markCapture 每快门 65k 次投影(热循环已标量化零分配)= 个位数 ms;
  ///   packed 全量打包 65k 点 = 个位数 ms;淘汰整理(堆式 top-k,不再全量
  ///   排序)= 个位数 ms,且每 ~[_pruneSlack] 个新体素才一次;推送 payload
  ///   65k×15B ≈ 975KB × 实际频率(每快门 ~0.4Hz + 真值注入 ~0.3Hz,已加
  ///   400ms 合并节流,见 ar_capture_page._scheduleCoveragePush)≈ 数百
  ///   KB/s 峰值。渲染 = native 哑点精灵单 draw call(App 最终点云预览已
  ///   渲 62k+ 点无帧率投诉;真机 FPS 由 resource 遥测域装机波次复核)。
  /// 上限只是安全阀 —— 真正的功能保证在淘汰序(见 [_pruneIfNeeded]:
  /// 新区永远不输给已饱和老区)。
  final int maxVoxels;

  /// Photos needed for full "green".
  final int coverageSaturation;

  /// 转绿所需的最小视差角(度)。观测次数达标但 maxParallaxDeg 低于此值的
  /// 体素停在黄色——纯计数会把"原地连拍"误报成绿,而低视差正是"双墙"
  /// (深度噪声壳)的成因。
  ///
  /// 阈值 5°(2026-07-11 校准,原 8° "取中偏严"被真机遥测否决):帧真值
  /// 中位分布中心 p50=8.75°,8° 扎在分布正中心 → 68% 已注册帧判黄(观感
  /// 80%+ 全场黄,引导失效);金标 LAPa 最终云 lt8=43.5% 且无重影(<8°
  /// 不等于坏),重影厚区实测特征 5.2° —— 5° 只圈真危险区。与帧卡片首判
  /// 锚(photo_card_state.kFrameYellowInitialDeg)同源同值。
  final double parallaxMinDeg;

  final Map<int, _CoverageVoxel> _voxels = <int, _CoverageVoxel>{};
  int _capturesMarked = 0;

  /// Route B 真值(voxel key → 该体素真实三角化角中位数,度):SfM worker
  /// 对流式 preview 云逐点算的真实视差,经 [applyTrueParallax] 注入。
  /// 独立于 [_voxels] 存放 —— preview 点落进的体素未必有 VIO 点(体素
  /// 后生也能立即拿到真值),体素被淘汰重生也不丢真值。
  final Map<int, double> _trueParallaxByKey = <int, double>{};

  /// 帧级视差归因(⚠️已退出 AR 卡片判定 —— 卡片判黄只用真值,见
  /// photo_card_state.frameLowParallaxTrue;本归因仅供诊断/工具断言):
  /// 每次 [markCapture] 记下该帧视锥命中的体素 key(近似:只归因当时已
  /// 存在的体素,之后新生的体素不回填)。体素的 maxParallaxDeg 会被后续
  /// 拍摄持续刷新,所以帧的中位视差随补拍增长。
  final Map<String, List<int>> _frameVoxelKeys = <String, List<int>>{};

  int get capturesMarked => _capturesMarked;
  int get coveredVoxelCount =>
      _voxels.values.where((v) => v.photoCoverage > 0).length;

  // Key 数学在 true_parallax.coverageVoxelKeyFor(21-bit 车道 + 0x100000
  // 偏移容负数)—— worker 侧体素聚合与这里必须逐位一致,所以共用一个函数。
  int _key(Vector3 p) => coverageVoxelKeyFor(p.x, p.y, p.z, voxelSizeM);

  /// Route B 真值注入:worker 对流式 preview 云算出的"voxel key → 真实
  /// 三角化角中位数"(key 用 [coverageVoxelKeyFor] @ [kCoverageVoxelSizeM]
  /// 计算,与 [_key] 同函数)。合并式 upsert:本次没被采样到的体素保留
  /// 旧真值(点云在长大、几秒级陈旧可接受),避免黄绿闪烁。
  /// [voxelSizeM] 被定制成非共享常量时 key 语义不对齐 → 整批忽略
  /// (产品恒用默认;这是防御,不是功能)。
  void applyTrueParallax(Int64List keys, Float32List degs) {
    if (keys.length != degs.length || voxelSizeM != kCoverageVoxelSizeM) {
      return;
    }
    for (var i = 0; i < keys.length; i++) {
      _trueParallaxByKey[keys[i]] = degs[i];
    }
  }

  /// 体素有效视差(度):真实三角化角(route B)优先,真值未到达的体素
  /// 回退视锥近似 maxParallaxDeg(route A,已实锤过松 —— 仅兜底)。
  double _effectiveParallaxDeg(int key, _CoverageVoxel v) =>
      _trueParallaxByKey[key] ?? v.maxParallaxDeg;

  /// Tracker tick: keep voxel positions fresh. Never lights anything up.
  void ingestPose(ARPose pose) {
    if (pose.previewPoints.isEmpty) return;
    for (final point in pose.previewPoints) {
      final k = _key(point.position);
      final v = _voxels[k];
      if (v != null) {
        v.position = point.position.clone();
        v.seen = math.min(v.seen + 1, 60);
      } else {
        _voxels[k] = _CoverageVoxel(point.position.clone());
      }
    }
    _pruneIfNeeded(pose.position);
  }

  /// 淘汰缓冲:超过 [maxVoxels] 后允许再涨这么多才触发一次整理,把整理
  /// 成本从"每 pose tick"摊薄到"每 ~slack 个新体素一次"(pose 流
  /// 30-60Hz 在主 isolate 上)。65k 配额下 slack ≈ 1015:整理触发间隔按
  /// 新体素发现速率(每 tick 数十个)≈ 秒级一次,单次堆式整理个位数 ms。
  int get _pruneSlack => math.max(8, maxVoxels ~/ 64);

  /// 累计被淘汰的体素数(遥测【guidance】对数用:>0 说明本场景摸到了
  /// 容量安全阀,该考虑再提上限或 LOD 粗化)。
  int get evictedTotal => _evictedTotal;
  int _evictedTotal = 0;

  /// 容量淘汰(2026-07-11 案②重写,46 号"覆盖点拍着拍着不更新"根因):
  ///
  /// 铁律:**引导功能的使命是显示未覆盖区,新区永远不能输给已饱和老区。**
  /// 旧序(photoCoverage DESC, seen DESC)正好反了 —— 6000 个体素全部
  /// covered 后,新区体素(coverage 0/1)插入即被老区饱和体素挤出。
  ///
  /// 新淘汰序(先淘汰 → 后淘汰):
  ///   1. 绿体素(观测 ≥ 饱和 且 有效视差达标)——引导价值已耗尽,
  ///      其中距当前相机最远的最先走;
  ///   2. 其余(未覆盖 / 红 / 黄,含视差饥饿黄)——都还在引导("这里
  ///      还没拍够"或"新区候选"),按距当前相机最远先走。
  /// 新区体素永远贴着当前相机(用户正在拍的地方)→ 插入必胜。
  ///
  /// 实现(65k 提额后重写):不再全量排序(66k 记录 comparator 排序在主
  /// isolate 是几十 ms 量级),改**固定容量 min-heap 选 top-k**(k =
  /// 超额数 ≈ slack):O(n log k)、零记录对象分配,单次个位数 ms。
  /// 淘汰分 = dist²(+绿类 1e12 偏移,保证"绿整类先于其他淘汰"的
  /// 字典序;dist² << 1e12,双精度下两级互不干扰)。分数完全相同的
  /// 极端平手淘汰顺序不保证(真实场景 dist² 平手概率≈0)。
  ///
  /// tool/coverage_eviction_check.dart 固化"新区插入必胜"回归断言
  /// (含 65k 满载性能断言)。
  void _pruneIfNeeded(Vector3 camPos) {
    final k = _voxels.length - maxVoxels;
    if (k <= _pruneSlack) return;
    // min-heap(根 = 当前 top-k 淘汰分里最小的那个):遍历一遍,分数
    // 高于根的顶掉根。结束时堆里就是 k 个最该淘汰的体素。
    final heapScore = Float64List(k);
    final heapKey = List<int>.filled(k, 0);
    var n = 0;
    final cxCam = camPos.x, cyCam = camPos.y, czCam = camPos.z;
    for (final e in _voxels.entries) {
      final v = e.value;
      final dx = v.position.x - cxCam;
      final dy = v.position.y - cyCam;
      final dz = v.position.z - czCam;
      var score = dx * dx + dy * dy + dz * dz;
      if (v.photoCoverage >= coverageSaturation &&
          _effectiveParallaxDeg(e.key, v) >= parallaxMinDeg) {
        score += 1.0e12; // 绿:引导价值耗尽,整类先于未覆盖/红/黄淘汰
      }
      if (n < k) {
        var i = n++;
        heapScore[i] = score;
        heapKey[i] = e.key;
        while (i > 0) {
          final parent = (i - 1) >> 1;
          if (heapScore[parent] <= heapScore[i]) break;
          final ts = heapScore[parent];
          heapScore[parent] = heapScore[i];
          heapScore[i] = ts;
          final tk = heapKey[parent];
          heapKey[parent] = heapKey[i];
          heapKey[i] = tk;
          i = parent;
        }
      } else if (score > heapScore[0]) {
        heapScore[0] = score;
        heapKey[0] = e.key;
        var i = 0;
        while (true) {
          final l = 2 * i + 1;
          if (l >= k) break;
          var m = l;
          final r = l + 1;
          if (r < k && heapScore[r] < heapScore[l]) m = r;
          if (heapScore[i] <= heapScore[m]) break;
          final ts = heapScore[i];
          heapScore[i] = heapScore[m];
          heapScore[m] = ts;
          final tk = heapKey[i];
          heapKey[i] = heapKey[m];
          heapKey[m] = tk;
          i = m;
        }
      }
    }
    for (var i = 0; i < n; i++) {
      _voxels.remove(heapKey[i]);
    }
    _evictedTotal += n;
  }

  /// One committed shutter = one coverage pass: project every voxel into the
  /// captured frame (frame-exact camera-to-world + full-res intrinsics from
  /// the SfmFrameFeed) and bump the ones the photo saw. Returns true when
  /// any voxel's coverage changed (i.e. the render payload is stale).
  bool markCapture(SfmFrameFeed feed) {
    if (feed.extrinsic4x4.length != 16 ||
        feed.intrinsicFxFyCxCy.length < 4 ||
        feed.imageW <= 0 ||
        feed.imageH <= 0) {
      return false;
    }
    final c2w = vm.Matrix4.fromList(feed.extrinsic4x4);
    final rW2c = c2w.getRotation()..transpose();
    final tC2w = c2w.getTranslation();
    final fx = feed.intrinsicFxFyCxCy[0];
    final fy = feed.intrinsicFxFyCxCy[1];
    final cx = feed.intrinsicFxFyCxCy[2];
    final cy = feed.intrinsicFxFyCxCy[3];
    final w = feed.imageW.toDouble();
    final h = feed.imageH.toDouble();

    var changed = false;
    // 帧级视差归因:按 jpegPath 记录本帧命中的体素(卡片状态与 SfM
    // fedFrameMeta 都以 jpegPath 为键,这里保持同一把钥匙)。
    final jpegPath = feed.jpegPath;
    final hitKeys = jpegPath != null ? <int>[] : null;
    // 热循环标量化(65k 提额,2026-07-11):原 `rW2c.transform(v.position
    // - tC2w)` + `v.position - tC2w` 每体素分配 2 个 Vector3,65k 体素/
    // 快门 = 13 万次分配。全部展开为标量算术 —— 与 vector_math 的
    // Matrix3.transform(列主序)/ operator- / length²(z²+y²+x² 序)/
    // dot(z·z+y·y+x·x 序)/ scale(1/len)逐运算同序,数值逐位一致;
    // 分配只剩每体素一次的首观测视线(体素生命周期一次)。
    final rs = rW2c.storage; // 列主序 3×3
    final r0 = rs[0], r1 = rs[1], r2 = rs[2];
    final r3 = rs[3], r4 = rs[4], r5 = rs[5];
    final r6 = rs[6], r7 = rs[7], r8 = rs[8];
    final tx = tC2w.x, ty = tC2w.y, tz = tC2w.z;
    for (final entry in _voxels.entries) {
      final v = entry.value;
      final p = v.position;
      final wx = p.x - tx, wy = p.y - ty, wz = p.z - tz;
      // Camera space (ARKit convention: -z forward, +y up).
      final pcx = r0 * wx + r3 * wy + r6 * wz;
      final pcy = r1 * wx + r4 * wy + r7 * wz;
      final pcz = r2 * wx + r5 * wy + r8 * wz;
      final depth = -pcz;
      if (depth < 0.05 || depth > 40) continue;
      // Image pixels: origin top-left, +y down → flip camera-space y.
      final u = fx * (pcx / depth) + cx;
      final vpx = fy * (-pcy / depth) + cy;
      if (u < 0 || u >= w || vpx < 0 || vpx >= h) continue;
      // 视差累计:记录首观测视线(相机中心→体素,世界系单位向量),此后
      // 每次命中都用当前视线与首视线的夹角刷新 maxParallaxDeg。
      final viewLen2 = wz * wz + wy * wy + wx * wx;
      if (viewLen2 > 1e-12) {
        final invLen = 1.0 / math.sqrt(viewLen2);
        final vx = wx * invLen, vy = wy * invLen, vz = wz * invLen;
        final first = v.firstViewDir;
        if (first == null) {
          v.firstViewDir = Vector3(vx, vy, vz);
        } else {
          final cosAng = (first.z * vz + first.y * vy + first.x * vx).clamp(
            -1.0,
            1.0,
          );
          final angDeg = math.acos(cosAng) * 180.0 / math.pi;
          if (angDeg > v.maxParallaxDeg) v.maxParallaxDeg = angDeg;
        }
      }
      v.photoCoverage++;
      hitKeys?.add(entry.key);
      changed = true;
    }
    if (jpegPath != null && hitKeys != null && hitKeys.isNotEmpty) {
      _frameVoxelKeys[jpegPath] = hitKeys;
    }
    _capturesMarked++;
    return changed;
  }

  /// Packs only photo-covered voxels (0 captures ⇒ empty payload ⇒ the
  /// renderer clears). Ramp: 1 photo → red/orange, 2-3 → yellow,
  /// ≥[coverageSaturation] → green.
  ///
  /// 低视差压黄策略(信号1):观测次数达标但有效视差(真实三角化角优先,
  /// 视锥近似兜底,见 [_effectiveParallaxDeg])< [parallaxMinDeg] 的体素
  /// 把 ramp 参数封在 0.5(纯黄),不给绿——二进制布局(xyz 3×f32 +
  /// rgb 3×u8,逐点同序)绝不改变,只改颜色值。
  CoverageCloudPacked packed() {
    final covered = _voxels.entries
        .where((e) => e.value.photoCoverage > 0)
        .toList();
    final xyz = Float32List(covered.length * 3);
    final rgb = Uint8List(covered.length * 3);
    for (var i = 0; i < covered.length; i++) {
      final v = covered[i].value;
      final o = i * 3;
      xyz[o] = v.position.x;
      xyz[o + 1] = v.position.y;
      xyz[o + 2] = v.position.z;
      var t = math.min(v.photoCoverage / coverageSaturation, 1.0);
      // 低视差不给绿:停在黄(t=0.5)。低视差=深度噪声壳("双墙")高危区。
      if (t > 0.5 &&
          _effectiveParallaxDeg(covered[i].key, v) < parallaxMinDeg) {
        t = 0.5;
      }
      final r = t < 0.5 ? 1.0 : (1.0 - (t - 0.5) * 2.0);
      final g = t < 0.5 ? (t * 2.0) : 1.0;
      rgb[o] = (r * 255).round();
      rgb[o + 1] = (g * 255).round();
      rgb[o + 2] = 20;
    }
    return CoverageCloudPacked(xyz, rgb);
  }

  /// UI 访问器(信号1):查询 [worldPos] 所在体素的有效视差角(度,真实
  /// 三角化角优先、视锥近似兜底)。该位置没有体素、或还没被任何照片拍到
  /// 时返回 null。
  double? parallaxDegAt(Vector3 worldPos) {
    final k = _key(worldPos);
    final v = _voxels[k];
    if (v == null || v.photoCoverage == 0) return null;
    return _effectiveParallaxDeg(k, v);
  }

  /// 帧级视差聚合(⚠️已退出卡片判定:白→黄反序修复后卡片判黄只用真值,
  /// 真值未到达保持黑 —— 见 photo_card_state.frameLowParallaxTrue。本
  /// 方法仅供诊断/工具断言):帧 [jpegPath] 在 [markCapture] 时命中体素
  /// 的有效视差**当前值**的中位数(体素真值到达后这里也跟着变准)。帧未
  /// 标记过/体素已被淘汰殆尽时返回 null(证据缺失,调用方不应判黄)。
  double? frameMedianParallaxDeg(String jpegPath) {
    final keys = _frameVoxelKeys[jpegPath];
    if (keys == null || keys.isEmpty) return null;
    final degs = <double>[];
    for (final k in keys) {
      final v = _voxels[k];
      if (v == null || v.photoCoverage == 0) continue; // 已淘汰/未覆盖
      degs.add(_effectiveParallaxDeg(k, v));
    }
    return medianOf(degs);
  }

  /// 帧级低视差判定(⚠️已退出卡片判定,仅诊断/工具断言,理由同上):
  /// 中位视差 < [parallaxMinDeg](5°,与体素压黄同源)。
  /// null(无证据)→ false,不惩罚。
  bool isFrameLowParallax(String jpegPath) {
    final med = frameMedianParallaxDeg(jpegPath);
    return med != null && med < parallaxMinDeg;
  }

  /// UI 访问器(信号1):观测次数已达标(≥[coverageSaturation])但有效
  /// 视差不足(<[parallaxMinDeg])而被压在黄色的体素数。>0 时 UI 应提示
  /// "换角度再拍此区域"(RS 式引导)。
  int get parallaxStarvedVoxelCount => _voxels.entries
      .where(
        (e) =>
            e.value.photoCoverage >= coverageSaturation &&
            _effectiveParallaxDeg(e.key, e.value) < parallaxMinDeg,
      )
      .length;

  /// 遥测【guidance】只读统计(任务 D):覆盖云红/黄/绿体素计数,分类与
  /// [packed] 的 ramp 同语义(1 张 → 红;2..饱和-1 → 黄;≥饱和 → 绿,
  /// 但低视差压黄计入 parallaxCapped —— 现在用有效视差:真值优先)。
  /// Route B 对数字段:
  ///   trueVoxels  = 已覆盖体素里拿到真实三角化角的数量(真值到达率);
  ///   trueLt8     = 其中真值 < [parallaxMinDeg] 的数量(字段名沿革自旧锚
  ///                 8°,2026-07-11 阈值校准后口径 = <5°;历史对数:最终云
  ///                 点级 <8° 占比实锤 40.3%,金标 LAPa 43.5% 且无重影);
  ///   starvedTrue = 观测达标(≥饱和)且**真值**不足的体素数(route A
  ///                 同口径 starved 上次只报 1/5997,这里是真值版)。
  /// 只遍历不改状态,packed 布局不动。
  ({
    int covered,
    int red,
    int yellow,
    int green,
    int parallaxCapped,
    int trueVoxels,
    int trueLt8,
    int starvedTrue,
  })
  coverageStats() {
    var red = 0, yellow = 0, green = 0, capped = 0;
    var trueVoxels = 0, trueLt8 = 0, starvedTrue = 0;
    for (final e in _voxels.entries) {
      final v = e.value;
      if (v.photoCoverage == 0) continue;
      final trueDeg = _trueParallaxByKey[e.key];
      if (trueDeg != null) {
        trueVoxels++;
        if (trueDeg < parallaxMinDeg) {
          trueLt8++;
          if (v.photoCoverage >= coverageSaturation) starvedTrue++;
        }
      }
      if (v.photoCoverage >= coverageSaturation) {
        if (_effectiveParallaxDeg(e.key, v) < parallaxMinDeg) {
          yellow++;
          capped++; // 观测够但视差不足 → 压黄(双墙高危区)
        } else {
          green++;
        }
      } else if (v.photoCoverage == 1) {
        red++;
      } else {
        yellow++;
      }
    }
    return (
      covered: red + yellow + green,
      red: red,
      yellow: yellow,
      green: green,
      parallaxCapped: capped,
      trueVoxels: trueVoxels,
      trueLt8: trueLt8,
      starvedTrue: starvedTrue,
    );
  }

  void reset() {
    _voxels.clear();
    _frameVoxelKeys.clear();
    _trueParallaxByKey.clear();
    _capturesMarked = 0;
    _evictedTotal = 0;
  }
}
