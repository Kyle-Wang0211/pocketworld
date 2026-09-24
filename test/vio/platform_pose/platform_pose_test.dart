// platform_pose_test.dart — 条目 14 的单测 + 负向对照。
//
// 放在 lib/vio/platform_pose/ 内是 territory 纪律的结果(本 agent 只许在此
// 目录建文件)。跑法:
//   flutter test lib/vio/platform_pose/platform_pose_test.dart
// 主会话若要并入常规 test/ 树,见交付说明里的 wiring patch(纯 git mv,
// 文件内容不需要改 —— import 用的是 package: 绝对路径)。

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:pocketworld_flutter/capture/true_parallax.dart'
    show cameraCenterFromCamFromWorld;
import 'package:pocketworld_flutter/official_capture/gravity_align.dart'
    show gravityAlignQuatWxyz;

import 'package:pocketworld_flutter/vio/platform_pose/extrinsics_contract.dart';
import 'package:pocketworld_flutter/vio/platform_pose/platform_pose_source.dart';

/// 测试替身:按 map 供样本。
class _FakeSource implements PlatformPoseSource {
  _FakeSource(
    this._samples, {
    this.platformId = 'fake',
    this.providesTimestamps = true,
    this.providesTrackingState = true,
  });

  final Map<int, PlatformPoseSample> _samples;

  @override
  final String platformId;
  @override
  final bool providesTimestamps;
  @override
  final bool providesTrackingState;

  @override
  PlatformPoseSample? sampleForFrame(int frameId) => _samples[frameId];
}

PoseUncertainty _platformOk() => PlatformPoseDefaults.arkitUncalibrated();

PlatformPoseSample _sample(
  int id, {
  List<double>? quat,
  List<double>? trans,
  PlatformTrackingState tracking = PlatformTrackingState.normal,
  PoseUncertainty? unc,
}) => PlatformPoseSample(
  frameId: id,
  quatWxyz: quat ?? [1.0, 0.0, 0.0, 0.0],
  translation: trans,
  tracking: tracking,
  uncertainty: unc ?? _platformOk(),
);

void main() {
  // ───────────────────────────────────────────────────────────────────────
  group('闸一:sigma<=0 / 非有限 = 无穷权重 = fixed constraint,必须抛', () {
    test('rotationSigmaRad = 0 抛', () {
      expect(
        () => PoseUncertainty(
          provenance: PoseProvenance.selfSolvedSfm,
          rotationSigmaRad: 0.0,
          translationSigmaM: 0.01,
          gravitySigmaRad: 0.01,
        ),
        throwsArgumentError,
      );
    });

    test('translationSigmaM = 0 抛(这是 fixed constraint 最常见的伪装)', () {
      expect(
        () => PoseUncertainty(
          provenance: PoseProvenance.selfSolvedSfm,
          rotationSigmaRad: 0.01,
          translationSigmaM: 0.0,
          gravitySigmaRad: 0.01,
        ),
        throwsArgumentError,
      );
    });

    test('负数与 NaN / Infinity 一并抛', () {
      for (final bad in [-1.0, double.nan, double.infinity]) {
        expect(
          () => PoseUncertainty(
            provenance: PoseProvenance.selfSolvedSfm,
            rotationSigmaRad: 0.01,
            translationSigmaM: bad,
            gravitySigmaRad: 0.01,
          ),
          throwsArgumentError,
          reason: 'translationSigmaM=$bad 应当被拒',
        );
      }
    });

    test('信息权重按构造有限(σ>0 已强制 ⇒ 不可能是 infinity)', () {
      final u = _platformOk();
      expect(u.informationWeightRotation().isFinite, isTrue);
      expect(u.informationWeightTranslation().isFinite, isTrue);
      expect(u.informationWeightGravity().isFinite, isTrue);
      expect(u.informationWeightScale()!.isFinite, isTrue);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('闸二:platform 来源的 sigma 不得低于实测下限', () {
    test('平移 σ = 1mm 被拒(远小于日方实测的 4.0cm)', () {
      expect(
        () => PoseUncertainty(
          provenance: PoseProvenance.platform,
          rotationSigmaRad: kPlatformRotationSigmaFloorRad,
          translationSigmaM: 0.001,
          gravitySigmaRad: kPlatformRotationSigmaFloorRad,
        ),
        throwsArgumentError,
      );
    });

    test('旋转 / 重力 / 尺度 σ 低于下限同样被拒', () {
      PoseUncertainty build({double? rot, double? grav, double? scale}) =>
          PoseUncertainty(
            provenance: PoseProvenance.platform,
            rotationSigmaRad: rot ?? kPlatformRotationSigmaFloorRad,
            gravitySigmaRad: grav ?? kPlatformRotationSigmaFloorRad,
            translationSigmaM: kPlatformTranslationSigmaFloorM,
            scaleSigmaRel: scale ?? kPlatformScaleSigmaFloorRel,
          );
      expect(
        () => build(rot: kPlatformRotationSigmaFloorRad * 0.5),
        throwsArgumentError,
      );
      expect(
        () => build(grav: kPlatformRotationSigmaFloorRad * 0.5),
        throwsArgumentError,
      );
      expect(
        () => build(scale: kPlatformScaleSigmaFloorRel * 0.5),
        throwsArgumentError,
      );
    });

    test('恰好等于下限放行(闸是 <,不是 <=)', () {
      expect(
        () => PoseUncertainty(
          provenance: PoseProvenance.platform,
          rotationSigmaRad: kPlatformRotationSigmaFloorRad,
          gravitySigmaRad: kPlatformRotationSigmaFloorRad,
          translationSigmaM: kPlatformTranslationSigmaFloorM,
          scaleSigmaRel: kPlatformScaleSigmaFloorRel,
        ),
        returnsNormally,
      );
    });

    test('自研解不受平台下限约束(它本来就该更准)', () {
      expect(
        () => PoseUncertainty(
          provenance: PoseProvenance.selfSolvedSfm,
          rotationSigmaRad: 1e-5,
          translationSigmaM: 1e-4,
          gravitySigmaRad: 1e-5,
        ),
        returnsNormally,
      );
    });

    test('两个平台默认值都能构造,且 Android XR 一律不比 ARKit 更自信', () {
      final ark = PlatformPoseDefaults.arkitUncalibrated();
      final xr = PlatformPoseDefaults.androidXrUncalibrated();
      expect(xr.rotationSigmaRad, greaterThanOrEqualTo(ark.rotationSigmaRad));
      expect(xr.translationSigmaM, greaterThanOrEqualTo(ark.translationSigmaM));
      expect(xr.gravitySigmaRad, greaterThanOrEqualTo(ark.gravitySigmaRad));
      expect(xr.scaleSigmaRel!, greaterThanOrEqualTo(ark.scaleSigmaRel!));
    });

    test('纯单目来源可以不带米制尺度(scale 是 gauge 自由度不是测量)', () {
      final u = PoseUncertainty(
        provenance: PoseProvenance.selfSolvedSfm,
        rotationSigmaRad: 1e-3,
        translationSigmaM: 1e-3,
        gravitySigmaRad: 1e-3,
      );
      expect(u.carriesMetricScale, isFalse);
      expect(u.informationWeightScale(), isNull);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('相机中心换算与既有管线逐位一致', () {
    test('cameraCenterWorld == 既有 cameraCenterFromCamFromWorld', () {
      // 非平凡四元数(绕 (1,2,3) 归一轴转 ~1rad)与非平凡平移。
      final q = [
        0.8775825618903728,
        0.1281319011658407,
        0.2562638023316814,
        0.3843957034975221,
      ];
      final t = [0.31, -0.72, 1.44];
      final mine = _sample(0, quat: q, trans: t).cameraCenterWorld()!;
      final theirs = cameraCenterFromCamFromWorld(q, t)!;
      for (var i = 0; i < 3; i++) {
        expect(mine[i], closeTo(theirs[i], 1e-12), reason: 'axis $i');
      }
    });

    test('退化四元数(全 0)返回 null,与既有约定一致', () {
      final s = _sample(0, quat: [0, 0, 0, 0], trans: [1, 2, 3]);
      expect(s.cameraCenterWorld(), isNull);
      expect(cameraCenterFromCamFromWorld([0, 0, 0, 0], [1, 2, 3]), isNull);
    });

    test('没有平移时返回 null(只给朝向的来源)', () {
      expect(_sample(0).cameraCenterWorld(), isNull);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('用途闸', () {
    test('tracking 非 normal ⇒ 三个角色全拒', () {
      for (final st in [
        PlatformTrackingState.limited,
        PlatformTrackingState.unavailable,
      ]) {
        final s = _sample(0, trans: [0, 0, 0], tracking: st);
        for (final role in PlatformPoseRole.values) {
          expect(
            PlatformPoseGate.rejectionReason(s, role),
            PlatformPoseGate.reasonTrackingNotNormal,
            reason: '$st / $role',
          );
        }
      }
    });

    test('重力角色不被"没有平移"连坐(平台最可靠的一项)', () {
      final s = _sample(0); // 无平移
      expect(
        PlatformPoseGate.allows(s, PlatformPoseRole.gravityDirection),
        isTrue,
      );
      expect(
        PlatformPoseGate.rejectionReason(s, PlatformPoseRole.initialGuess),
        PlatformPoseGate.reasonNoTranslation,
      );
    });

    test('尺度角色要求携带米制尺度', () {
      final noScale = PoseUncertainty(
        provenance: PoseProvenance.platform,
        rotationSigmaRad: kPlatformRotationSigmaFloorRad,
        gravitySigmaRad: kPlatformRotationSigmaFloorRad,
        translationSigmaM: kPlatformTranslationSigmaFloorM,
      );
      final s = _sample(0, trans: [1, 2, 3], unc: noScale);
      expect(
        PlatformPoseGate.rejectionReason(s, PlatformPoseRole.scalePrior),
        PlatformPoseGate.reasonNoMetricScale,
      );
    });

    test('非 platform 来源不许走平台闸(避免自研解被当平台先验二次计权)', () {
      final self = PoseUncertainty(
        provenance: PoseProvenance.selfSolvedVio,
        rotationSigmaRad: 1e-3,
        translationSigmaM: 1e-3,
        gravitySigmaRad: 1e-3,
        scaleSigmaRel: 1e-3,
      );
      final s = _sample(0, trans: [1, 2, 3], unc: self);
      expect(
        PlatformPoseGate.rejectionReason(s, PlatformPoseRole.scalePrior),
        PlatformPoseGate.reasonNotPlatformProvenance,
      );
    });

    test('来源自报能力被如实透出(Android XR 无时间戳/无跟踪状态是真实情形)', () {
      final xrLike = _FakeSource(
        const {},
        platformId: 'android_xr',
        providesTimestamps: false,
        providesTrackingState: false,
      );
      expect(xrLike.platformId, 'android_xr');
      expect(xrLike.providesTimestamps, isFalse);
      expect(xrLike.providesTrackingState, isFalse);
      // 不给跟踪状态的平台,样本只能标 unavailable ⇒ 所有角色都拒。
      final s = _sample(
        0,
        trans: [1, 2, 3],
        tracking: PlatformTrackingState.unavailable,
      );
      for (final role in PlatformPoseRole.values) {
        expect(
          PlatformPoseGate.allows(s, role),
          isFalse,
          reason: '拿不到跟踪状态时不许假设它是好的 ($role)',
        );
      }
      // 没有时间戳的样本合法,但 timestampSeconds 必须是 null,不许伪造。
      expect(_sample(0).timestampSeconds, isNull);
    });

    test('缺样本 ⇒ no_sample', () {
      expect(
        PlatformPoseGate.rejectionReason(null, PlatformPoseRole.initialGuess),
        PlatformPoseGate.reasonNoSample,
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('适配器能被既有管线直接消费(端到端,跑的是既有函数本体)', () {
    // 合成一场:8 帧相机中心排成一条折线,BA 解出来的尺度比真实小 s_true 倍。
    // 平台给的是"真实"米制中心;既有 scaleAnchorFactor 应当把 s_true 找回来。
    const double sTrue = 1.06; // 6% gauge 漂移,落在 15% 拒收带内
    const int n = 8;

    final arkCenters = <int, List<double>>{};
    final poses = Float64List(n * 9);
    for (var i = 0; i < n; i++) {
      // 真实中心。
      final c = [i * 0.10, (i % 3) * 0.07, -(i * 0.05)];
      arkCenters[i] = c;
      // BA 中心 = 真实 / sTrue(⇒ 平台/BA 的距离比 = sTrue)。
      final cb = [c[0] / sTrue, c[1] / sTrue, c[2] / sTrue];
      // 单位旋转 ⇒ CamFromWorld 的 t = -R·C = -C。
      final o = i * 9;
      poses[o] = i.toDouble(); // frameId
      poses[o + 1] = 1.0; // registered
      poses[o + 2] = 1.0; // qw
      poses[o + 3] = 0.0;
      poses[o + 4] = 0.0;
      poses[o + 5] = 0.0;
      poses[o + 6] = -cb[0];
      poses[o + 7] = -cb[1];
      poses[o + 8] = -cb[2];
    }

    // [SCALE-ANCHOR RETIRED 2026-09-24] scaleCenterLookupOf 的两条用例随适配器
    // 一起删除(交付尺度改由 C++ 核 DEVICE-ALIGN-V1 负责)。

    test('gravityQuatLookupOf 喂进既有 gravityAlignQuatWxyz 能出解', () {
      final src = _FakeSource({
        for (var i = 0; i < n; i++) i: _sample(i, quat: [1, 0, 0, 0]),
      });
      final q = gravityAlignQuatWxyz(
        posesPacked: poses,
        arkitQuatWxyzOf: gravityQuatLookupOf(src),
      );
      expect(q, isNotNull);
      expect(q!.length, 4);
    });

    test('重力适配器不因缺平移而拒帧(与闸的规则一致)', () {
      final src = _FakeSource({
        for (var i = 0; i < n; i++) i: _sample(i, quat: [1, 0, 0, 0]),
      });
      final lookup = gravityQuatLookupOf(src);
      expect(lookup(0), isNotNull);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  group('外参"只应用一次"契约', () {
    const neutralYaml = '''
%YAML:1.0
output:
  q_bo: [ 0.0, 0.0, 0.0, 1.0 ] # x y z w
  p_bo: [ 0.0, 0.0, 0.0 ] # x y z [m]

solver:
  iteration_limit: 30
''';

    // 外参被烤进 output —— 这正是"从旧 commit / 旧机型 yaml 抄配置"会带进来的东西。
    const bakedYaml = '''
%YAML:1.0
output:
  q_bo: [ -0.7071068, 0.7071068, 0, 0 ] # x y z w
  p_bo: [ 0.0229970087959, 0.0754115110747, -0.0024726172229 ]
''';

    const managerApplies = '''
int XRSLAMManager::GetCameraPose(XRSLAMPose *pose) const {
    Pose camera_pose;
    camera_pose.q = latest_pose.q * config_->camera_to_body_rotation();
    camera_pose.p =
        latest_pose.p + latest_pose.q * config_->camera_to_body_translation();
    return XRSLAM_OK;
}
''';

    const managerNoLongerApplies = '''
int XRSLAMManager::GetCameraPose(XRSLAMPose *pose) const {
    Pose camera_pose = latest_pose;
    return XRSLAM_OK;
}
''';

    test('中性 yaml + 接口应用 = 恰好一次 = ok', () {
      final r = auditExtrinsicsSingleApplication(
        slamYamlSources: {'a.yaml': neutralYaml},
        managerCppSource: managerApplies,
      );
      expect(r.verdict, ExtrinsicsVerdict.ok);
      expect(r.passes, isTrue);
      expect(r.failures, isEmpty);
    });

    test('🔴 烤进 output 的 yaml + 接口也应用 = 应用两次 = 红', () {
      final r = auditExtrinsicsSingleApplication(
        slamYamlSources: {'neutral.yaml': neutralYaml, 'old.yaml': bakedYaml},
        managerCppSource: managerApplies,
      );
      expect(r.verdict, ExtrinsicsVerdict.doubleApplied);
      expect(r.passes, isFalse);
      expect(r.offendingYamls.map((f) => f.yamlName), ['old.yaml']);
      expect(r.failures.single, contains('TWICE'));
    });

    test('🔴 成对断言:接口不再应用时,中性 yaml 也必须红(否则外参一次都没应用)', () {
      final r = auditExtrinsicsSingleApplication(
        slamYamlSources: {'a.yaml': neutralYaml},
        managerCppSource: managerNoLongerApplies,
      );
      expect(r.verdict, ExtrinsicsVerdict.interfaceNoLongerApplies);
      expect(r.passes, isFalse);
      expect(r.failures.single, contains('ZERO times'));
    });

    test('缺省 output.q_bo 视为单位(config.cpp 默认 Identity)', () {
      final r = auditExtrinsicsSingleApplication(
        slamYamlSources: {'nooutput.yaml': 'solver:\n  iteration_limit: 30\n'},
        managerCppSource: managerApplies,
      );
      expect(r.verdict, ExtrinsicsVerdict.ok);
      expect(r.findings.single.qBo, isNull);
      expect(r.findings.single.isNeutral, isTrue);
    });

    test('w=-1 与 w=+1 是同一旋转,都算中性', () {
      final r = auditExtrinsicsSingleApplication(
        slamYamlSources: {
          'neg.yaml': 'output:\n  q_bo: [ 0, 0, 0, -1.0 ]\n  p_bo: [0,0,0]\n',
        },
        managerCppSource: managerApplies,
      );
      expect(r.verdict, ExtrinsicsVerdict.ok);
    });

    test('p_bo 非零单独也判红', () {
      final r = auditExtrinsicsSingleApplication(
        slamYamlSources: {
          'p.yaml': 'output:\n  q_bo: [0,0,0,1]\n  p_bo: [0.0229, 0.0754, 0]\n',
        },
        managerCppSource: managerApplies,
      );
      expect(r.verdict, ExtrinsicsVerdict.doubleApplied);
    });

    test('不把 sensor yaml 的 cam0.extrinsic.q_bc 误当成 output 外参', () {
      const sensor = '''
%YAML:1.0
cam0:
  extrinsic:
    q_bc: [-0.7071068, 0.7071068, 0, 0] # x y z w
    p_bc: [0.0229970087959, 0.0754115110747, -0.0024726172229]
''';
      final f = parseOutputExtrinsic('sensor.yaml', sensor);
      expect(f.qBo, isNull, reason: 'q_bc 不在 output 块下,必须不被采信');
      expect(f.isNeutral, isTrue);
    });

    // ── 判据自证的负向对照(08-22 教训:判据不能匹配注释)────────────────
    test('🔴 注释里的 camera_to_body_rotation() 不算"接口在应用"', () {
      const onlyInComment = '''
int XRSLAMManager::GetCameraPose(XRSLAMPose *pose) const {
    // 上游曾经在这里写 config_->camera_to_body_rotation();
    /* 也可能是块注释:config_->camera_to_body_translation(); */
    return XRSLAM_OK;
}
''';
      expect(
        interfaceAppliesCall(onlyInComment, 'camera_to_body_rotation'),
        isFalse,
      );
      expect(
        interfaceAppliesCall(onlyInComment, 'camera_to_body_translation'),
        isFalse,
      );
      // 对照:不剥注释就会误判 —— 证明剥注释这一步是真在起作用,不是摆设。
      expect(
        RegExp(r'camera_to_body_rotation\s*\(').hasMatch(onlyInComment),
        isTrue,
        reason: '原文确实含该串,所以上面的 isFalse 只能来自剥注释',
      );
    });
  });
}
