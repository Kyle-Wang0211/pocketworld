// 地点识别端到端:GFTT → ORB → 增量词典(RTAB-Map)→ TF-IDF → 哪张老照片最像。
//
// 这是**光流做不到而词袋做得到**的那一格。同一件事 LK 上面死过一次:跨大位移
// 时它会收敛到垃圾并报成功(老照片"匹配"156/160),判决被假阳性淹没。
// 方案与出处见 docs/handoffs/PLACE_RECOGNITION_RTABMAP_PLAN.md。
//
// 🔴 夹具用**真实感图像**(金标准里那批),不用合成哈希纹理:后者局部高度
// 自相似(内部最小汉明距只有 13),ORB 描述子本来就重,量化出的词没有区分度
// —— 第一版就是栽在这上面,词数 47/160、A 与 B 各共享 8x/160。
// 教训:判据没问题,夹具会骗人。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_controller.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_geometry.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_governor.dart';
import 'package:pocketworld_flutter/official_capture/shutter_backpressure_gate.dart';
import 'package:pocketworld_flutter/official_dome/ar_pose.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:pocketworld_flutter/official_capture/continuous_feature_tracks.dart';
import 'package:pocketworld_flutter/official_capture/orb_descriptor.dart';
import 'package:pocketworld_flutter/official_capture/visual_word_dictionary.dart';

const int _w = 128;
const int _h = 128;

/// 一帧 → 描述子。RTAB-Map 的 GFTT/ORB 路径:关键点不带方向(angle = −1),
/// 见 orb_descriptor.dart 文件头的查源结论。
List<Uint8List> describe(Uint8List gray) {
  final corners = goodFeaturesToTrack(
    gray: gray,
    width: _w,
    height: _h,
    maxCorners: kRtabmapMaxFeatures,
  );
  final blurred = orbBlurForDescriptors(gray, _w, _h);
  return <Uint8List>[
    for (final c in corners)
      computeOrbDescriptor(blurred, _w, _h, c.$1, c.$2, angleDeg: -1.0),
  ];
}

void main() {
  late List<Uint8List> images;
  late Map<String, Uint8List> views;

  setUpAll(() {
    final f = File('test/fixtures/orb_golden_opencv.json');
    expect(f.existsSync(), isTrue);
    final g = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    images = <Uint8List>[
      for (final c in (g['gftt'] as List))
        Uint8List.fromList(
          ((c as Map<String, dynamic>)['gray'] as List).cast<int>(),
        ),
    ];
    views = <String, Uint8List>{
      for (final e in (g['scene_views'] as Map<String, dynamic>).entries)
        e.key: Uint8List.fromList((e.value as List).cast<int>()),
    };
  });

  test('阳性对照:同一张图重新描述 ⇒ 共享绝大多数词', () {
    final dict = VisualWordDictionary();
    dict.addNewWords(describe(images[0]), 1);
    dict.addNewWords(describe(images[1]), 2);
    final q = dict.quantizeQuery(describe(images[0]));
    final (shared, total) = dict.sharedWordsWith(q, 1);
    expect(total, greaterThan(100), reason: '参考图词太少,判据没意义');
    expect(
      shared / total,
      greaterThan(0.9),
      reason:
          '同一张图应共享绝大多数词 —— 这正是 stella '
          'almost_all_lms_are_tracked 那道闸要的比例(0.9)',
    );
  });

  test('走开再回来:TF-IDF 指向**早就拍过的那张**,不是最近那张', () {
    final dict = VisualWordDictionary();
    dict.addNewWords(describe(images[0]), 1); // A:先拍
    dict.addNewWords(describe(images[1]), 2); // B:最近拍的,画面完全不同
    final q = dict.quantizeQuery(describe(images[0])); // 回到 A
    final likelihood = dict.computeLikelihood(q);
    final best = likelihood.entries.reduce(
      (x, y) => x.value >= y.value ? x : y,
    );
    expect(best.key, 1, reason: '若指向最近拍的 B,就还是 2026-09-10 用户报的那个 bug');
    final (sa, ta) = dict.sharedWordsWith(q, 1);
    final (sb, tb) = dict.sharedWordsWith(q, 2);
    expect(sa / ta, greaterThan(0.9));
    expect(sb / tb, lessThan(0.1));
    // ignore: avoid_print
    print(
      '  回到 A:与 A $sa/$ta,与 B $sb/$tb;'
      '似然 A=${likelihood[1]!.toStringAsFixed(4)} '
      'B=${likelihood[2]!.toStringAsFixed(4)}',
    );
  });

  test('阳性对照:真的换了内容 ⇒ 谁都认不出(别把闸焊死)', () {
    final dict = VisualWordDictionary();
    dict.addNewWords(describe(images[0]), 1);
    dict.addNewWords(describe(images[1]), 2);
    final q = dict.quantizeQuery(describe(images[2])); // 从没拍过的场景
    final (s1, t1) = dict.sharedWordsWith(q, 1);
    final (s2, t2) = dict.sharedWordsWith(q, 2);
    expect(s1 / t1, lessThan(0.9), reason: '全新画面不该被判成"拍过了"');
    expect(s2 / t2, lessThan(0.9));
    // ignore: avoid_print
    print('  全新画面:与 A $s1/$t1,与 B $s2/$t2');
  });

  test('同一场景小位移仍认得出,大位移则算新视角', () {
    final dict = VisualWordDictionary();
    dict.addNewWords(describe(views['same']!), 1);
    final near = dict.sharedWordsWith(
      dict.quantizeQuery(describe(views['near']!)),
      1,
    );
    final far = dict.sharedWordsWith(
      dict.quantizeQuery(describe(views['far']!)),
      1,
    );
    // ignore: avoid_print
    print(
      '  小位移 6px:${near.$1}/${near.$2}   大位移 48px:'
      '${far.$1}/${far.$2}',
    );
    expect(
      near.$1 / near.$2,
      greaterThan(far.$1 / far.$2),
      reason: '视角越近共享词越多 —— 这是判据有区分度的最低要求',
    );
  });

  test('词典是增量长出来的,不带预训练词表', () {
    final dict = VisualWordDictionary();
    expect(dict.wordCount, 0, reason: '出货成本 0 的前提:开局是空的');
    dict.addNewWords(describe(images[0]), 1);
    final afterFirst = dict.wordCount;
    expect(afterFirst, greaterThan(100));
    dict.addNewWords(describe(images[0]), 2);
    expect(
      dict.wordCount,
      lessThan((afterFirst * 1.2).round()),
      reason: '同一张图第二次进来,描述子应归到老词而不是造新词',
    );
    expect(dict.signatureCount, 2);
  });

  test('接进控制器:走开再回到拍过的视角 ⇒ 判重复,不再拍', () {
    // 端到端穿过 AutoCaptureController —— 这是用户 2026-09-10 圈出的那一格。
    var fires = 0;
    var captured = 0;
    final controller = AutoCaptureController(
      onStartAnchor: () => true,
      onFire: () {
        fires++;
        captured++;
        return true;
      },
      paceProvider: () => ShutterPace.normal,
      capturedCountProvider: () => captured,
      thermalStateProvider: () => 0,
      liveDepthProvider: (_) => 1.0,
      mapperAcceptingProvider: () => true,
    );

    ARPose poseAt(double t, double x, Uint8List gray) => ARPose(
      position: Vector3(x, 0, 0),
      orientation: Quaternion.identity(),
      azimuth: 0,
      elevation: 0,
      isTracking: true,
      trackingStateName: 'normal',
      timestamp: t,
      hasOrigin: true,
      worldOrigin: Vector3(0, 0, -1),
      worldYaw: 0,
      extrinsic4x4: const <double>[],
      intrinsicFxFyCxCy: const <double>[1000, 1000, 500, 500],
      imageWidth: 1000,
      imageHeight: 1000,
      quality: FrameQualityReport(
        sharpness: 1000,
        roiSharpness: 1000,
        multiScaleSharpness252: 1000,
        multiScaleSharpness512: 1000,
        edgeBlockSharpness: 1000,
        backgroundSharpness: 1000,
        subjectVsBackgroundSharpnessDelta: 0,
        sharpnessConsensus: 1000,
        meanBrightness: 128,
        globalVariance: 100,
        signature: Uint8List(256)..fillRange(0, 256, (t * 97).round() & 0xff),
        signatureWidth: 16,
        signatureHeight: 16,
        rawGray128: gray,
        sourceTimestamp: t,
        sourceFocalX: 128,
        sourceFocalY: 128,
      ),
      previewPoints: <ARPreviewPoint>[
        for (var i = 0; i < 12; i++)
          ARPreviewPoint(
            position: Vector3(x + i * 0.001, 0, -1),
            r: 0,
            g: 0,
            b: 0,
            confidence: 1,
          ),
      ],
    );

    AutoCaptureDecision feed(double t, double x, Uint8List gray) {
      final d = controller.onPose(poseAt(t, x, gray));
      if (d == AutoCaptureDecision.fire) {
        controller.onCaptureCompleted(captureTimestampSec: t);
      }
      return d;
    }

    // 用**同一场景横移**造轨迹:相机在现实里是渐进平移的,不会瞬移。
    // (第一版让它从 A 一步跳到完全不同的 B —— 传播式 LK 在那种巨大跳变上
    //  又给出假阳性,判成重复。那是夹具不真实,不是判据错。)
    Uint8List rolled(int dx) {
      final base = views['same']!;
      final out = Uint8List(_w * _h);
      for (var y = 0; y < _h; y++) {
        for (var x = 0; x < _w; x++) {
          out[y * _w + x] = base[y * _w + ((x + dx) % _w)];
        }
      }
      return out;
    }

    controller.start(poseAt(0, 0, rolled(0)));
    feed(0.1, 0, rolled(0)); // 起跑锚:这个视角进词典
    // 平移出去(每步 16 px = 12.5 cm,轨迹跟得住)。
    var t = 0.2;
    for (final dx in <int>[16, 32, 48, 64, 80, 96]) {
      feed(t, dx / 128.0, rolled(dx));
      t += 0.3;
    }
    expect(fires, greaterThan(0), reason: '一路平移过去总该拍到照片');
    final firesAway = fires;
    // 再原路平移回起点。
    for (final dx in <int>[80, 64, 48, 32, 16]) {
      feed(t, dx / 128.0, rolled(dx));
      t += 0.3;
    }
    final back = feed(t, 0, rolled(0)); // 回到起跑锚那个视角
    final scan = controller.lastPlaceRecognitionScan;
    expect(scan, isNotNull, reason: '地点识别没跑起来,判据无从谈起');
    // ignore: avoid_print
    print(
      '  控制器内:已拍 ${scan!.signatureCount} 张、词典 ${scan.wordCount} 词,'
      '命中 ${scan.bestSharedWords}/${scan.bestReferenceWords} '
      '(${(scan.bestSharedRatio * 100).toStringAsFixed(1)}%),'
      'describe ${(scan.describeMicros / 1000).toStringAsFixed(1)}ms '
      'query ${(scan.queryMicros / 1000).toStringAsFixed(1)}ms;'
      ' 去程拍了 $firesAway 张,回程判决 $back',
    );
    expect(
      back,
      isNot(AutoCaptureDecision.fire),
      reason: '这个视角起跑就拍过 —— 回来还开火就是用户 2026-09-10 报的那个 bug',
    );
  });
}
