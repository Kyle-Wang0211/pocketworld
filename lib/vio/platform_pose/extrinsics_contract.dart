// extrinsics_contract.dart — 外参"只许应用一次"契约的静态断言(条目 14 第 3 条)。
// 纯 Dart,零 Flutter 依赖,零 I/O:全部是对**源文本**的纯函数分析,
// 因此可以直接进 CI,不需要编译 xrslam,也不需要真机。
//
// ── 要防的 bug 是什么(在**我们自己的树**里定位过,不是转述上游)────────
// 上游 PR#70 报的现象是"外参被应用两次 ⇒ tracking 看起来正常,但虚拟物体
// 反向漂移"。在我们这棵树里,这条链的两个环节都在,位置精确如下:
//
//   环节 A(输出侧,SLAM 核内):
//     xrslam/src/xrslam/core/detail.cpp:266
//       output_pose.q = state_pose.q * config->output_to_body_rotation();
//     ⇒ get_latest_pose() 返回的位姿**已经乘过** output.q_bo。
//
//   环节 B(接口侧):
//     xrslam-interface/src/XRSLAMManager.cpp:685
//       camera_pose.q = latest_pose.q * config_->camera_to_body_rotation();
//     ⇒ 在 A 的结果上**再乘一次** cam0.extrinsic.q_bc。
//
//   合起来:GetCameraPose() 返回 state.q · q_bo · q_bc。
//
// 我们现在是安全的,原因**只有一个**:全部 slam yaml 的 output.q_bo 都是
// 单位四元数、p_bo 都是零(configs/iphone_slam.yaml、configs/euroc_slam.yaml、
// xrslam-ios/visualizer/configs/slam_params.yaml,2026-08-23 逐个核对)。
// 一旦有人从旧 commit / 别的机型抄一份把外参烤进 output.q_bo 的 yaml 进来,
// 就变成 state.q · q_bc · q_bc —— 外参被应用两次。
//
// ── 为什么必须是**成对**断言 ────────────────────────────────────────────
// 🔴 只断言 "q_bo 必须是单位四元数" 是不够的,而且很危险:
//    如果将来有人把环节 B 的那行乘法删掉(比如"重构掉一处重复"),
//    那么 q_bo=identity 就从"正确"变成"外参一次都没应用" —— 同样是错的,
//    而单边断言会**绿灯放行**。
//    所以本文件断言的是两者的**组合**:外参恰好被应用一次。
//      B 在  ⇒ 所有 yaml 的 q_bo 必须是 identity(外参由 B 提供)。
//      B 不在 ⇒ 契约变更,必须人工复核(不自动放行)。
//
// ── 关于判据自证(08-22 教训)──────────────────────────────────────────
// 🔴 判据绝不能匹配到注释。本文件所有匹配都在**剥掉注释之后**进行:
//    yaml 剥 '#' 到行尾,C++ 剥 '//' 到行尾与 /* */ 块。
//    上面这段注释里就写了 camera_to_body_rotation 与 q_bo 的字样 ——
//    如果不剥注释,把本文件自己喂进去都会"通过",那就是自证。
//    单测里有一条专门钉这件事。

// ── 判决 ────────────────────────────────────────────────────────────────

enum ExtrinsicsVerdict {
  /// 外参恰好应用一次。
  ok,

  /// 接口侧应用了 camera_to_body,同时至少一份 yaml 的 output 外参非单位
  /// ⇒ 外参被应用两次。
  doubleApplied,

  /// 接口侧没有应用 camera_to_body ⇒ 契约变更,需人工复核。
  interfaceNoLongerApplies,
}

/// 一份 slam yaml 的 output 外参解析结果。
class OutputExtrinsicFinding {
  const OutputExtrinsicFinding({
    required this.yamlName,
    required this.qBo,
    required this.pBo,
  });

  final String yamlName;

  /// output.q_bo,顺序 [x,y,z,w](与 yaml 注释里的排列一致)。
  /// null = 该 yaml **没有**写 output.q_bo。
  final List<double>? qBo;

  /// output.p_bo,[x,y,z]。null = 没写。
  final List<double>? pBo;

  /// 旋转是否为单位四元数(含 w=-1 的同一旋转)。
  ///
  /// 🔴 **缺省即单位**:xrslam/src/xrslam/config.cpp 的
  /// Config::output_to_body_rotation() 默认返回 quaternion::Identity(),
  /// yaml_config.cpp 仅在节点存在时覆盖 ⇒ 没写 q_bo 等价于写了单位四元数。
  /// 所以 null 判为 true,不是判为可疑。
  bool get rotationIsIdentity {
    final q = qBo;
    if (q == null) return true;
    if (q.length != 4) return false;
    final x = q[0], y = q[1], z = q[2], w = q[3];
    if (![x, y, z, w].every((v) => v.isFinite)) return false;
    const tol = 1e-6;
    return x.abs() <= tol &&
        y.abs() <= tol &&
        z.abs() <= tol &&
        (w.abs() - 1.0).abs() <= tol;
  }

  /// 平移是否为零(缺省即零,理由同上)。
  bool get translationIsZero {
    final p = pBo;
    if (p == null) return true;
    if (p.length != 3) return false;
    const tol = 1e-9;
    return p.every((v) => v.isFinite && v.abs() <= tol);
  }

  bool get isNeutral => rotationIsIdentity && translationIsZero;
}

/// 审计结果。
class ExtrinsicsAuditResult {
  const ExtrinsicsAuditResult({
    required this.interfaceAppliesCameraToBodyRotation,
    required this.interfaceAppliesCameraToBodyTranslation,
    required this.findings,
  });

  /// 接口侧(XRSLAMManager)是否仍在自行乘 camera_to_body 旋转。
  final bool interfaceAppliesCameraToBodyRotation;

  /// 接口侧是否仍在自行加 camera_to_body 平移。
  final bool interfaceAppliesCameraToBodyTranslation;

  final List<OutputExtrinsicFinding> findings;

  bool get interfaceApplies =>
      interfaceAppliesCameraToBodyRotation ||
      interfaceAppliesCameraToBodyTranslation;

  /// 非中性(把外参烤进 output)的 yaml。
  List<OutputExtrinsicFinding> get offendingYamls =>
      findings.where((f) => !f.isNeutral).toList(growable: false);

  ExtrinsicsVerdict get verdict {
    if (!interfaceApplies) return ExtrinsicsVerdict.interfaceNoLongerApplies;
    if (offendingYamls.isNotEmpty) return ExtrinsicsVerdict.doubleApplied;
    return ExtrinsicsVerdict.ok;
  }

  bool get passes => verdict == ExtrinsicsVerdict.ok;

  /// 人类可读的失败说明;通过时为空。
  List<String> get failures {
    switch (verdict) {
      case ExtrinsicsVerdict.ok:
        return const [];
      case ExtrinsicsVerdict.interfaceNoLongerApplies:
        return [
          'XRSLAMManager no longer multiplies camera_to_body; the camera '
              'extrinsic would now be applied ZERO times unless every slam '
              'yaml bakes it into output.q_bo/p_bo. This is a contract change '
              'and needs human review, not a green build.',
        ];
      case ExtrinsicsVerdict.doubleApplied:
        return offendingYamls
            .map(
              (f) =>
                  '${f.yamlName}: output extrinsic is non-neutral '
                  '(q_bo=${f.qBo}, p_bo=${f.pBo}) while XRSLAMManager also '
                  'applies camera_to_body -> the extrinsic is applied TWICE. '
                  'Symptom: tracking looks fine, virtual content drifts the '
                  'wrong way.',
            )
            .toList(growable: false);
    }
  }
}

// ── 注释剥离 ────────────────────────────────────────────────────────────

/// 剥掉 YAML 的 '#' 行内注释。逐行处理,保留行结构(行号可对得上)。
///
/// 这些 yaml 里没有含 '#' 的字符串字面量(全是数字数组与裸标量),
/// 所以不做引号感知 —— 做了反而是没有证据支撑的复杂度。
String stripYamlComments(String src) {
  return src
      .split('\n')
      .map((line) {
        final i = line.indexOf('#');
        return i < 0 ? line : line.substring(0, i);
      })
      .join('\n');
}

/// 剥掉 C/C++ 的 '//' 行注释与 '/* */' 块注释。
/// 不做字符串字面量感知:被扫的是位姿计算代码,不含带 '//' 的字符串。
String stripCppComments(String src) {
  final out = StringBuffer();
  var i = 0;
  final n = src.length;
  while (i < n) {
    if (i + 1 < n && src[i] == '/' && src[i + 1] == '/') {
      while (i < n && src[i] != '\n') {
        i++;
      }
    } else if (i + 1 < n && src[i] == '/' && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < n && !(src[i] == '*' && src[i + 1] == '/')) {
        if (src[i] == '\n') out.write('\n');
        i++;
      }
      i = (i + 1 < n) ? i + 2 : n;
    } else {
      out.write(src[i]);
      i++;
    }
  }
  return out.toString();
}

// ── 解析 ────────────────────────────────────────────────────────────────

/// 从 slam yaml 源文本里解析 output.q_bo / output.p_bo。
///
/// 只认**顶层 `output:` 块下**的键 —— 传感器 yaml 里 cam0.extrinsic 的
/// q_bc/p_bc 与本契约无关,绝不能混进来。
OutputExtrinsicFinding parseOutputExtrinsic(String yamlName, String yamlSrc) {
  final lines = stripYamlComments(yamlSrc).split('\n');
  List<double>? q;
  List<double>? p;
  var inOutput = false;
  for (final raw in lines) {
    if (raw.trim().isEmpty) continue;
    final indent = raw.length - raw.trimLeft().length;
    final trimmed = raw.trim();
    if (indent == 0) {
      // 顶层键:进入或离开 output 块。
      inOutput = RegExp(r'^output\s*:').hasMatch(trimmed);
      continue;
    }
    if (!inOutput) continue;
    final m = RegExp(r'^(q_bo|p_bo)\s*:\s*(.*)$').firstMatch(trimmed);
    if (m == null) continue;
    final vals = _parseInlineList(m.group(2)!);
    if (m.group(1) == 'q_bo') {
      q = vals;
    } else {
      p = vals;
    }
  }
  return OutputExtrinsicFinding(yamlName: yamlName, qBo: q, pBo: p);
}

/// 解析 `[ a, b, c ]` 形式的行内数组。解析不出来返回 null。
List<double>? _parseInlineList(String s) {
  final open = s.indexOf('[');
  final close = s.lastIndexOf(']');
  if (open < 0 || close <= open) return null;
  final body = s.substring(open + 1, close);
  final parts = body
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  if (parts.isEmpty) return null;
  final out = <double>[];
  for (final part in parts) {
    final v = double.tryParse(part);
    if (v == null) return null;
    out.add(v);
  }
  return out;
}

/// 检测 XRSLAMManager 源文本是否仍自行应用 camera_to_body 外参。
///
/// 匹配的是**函数调用**(标识符后面紧跟左括号),且在剥注释之后进行。
bool interfaceAppliesCall(String cppSrc, String symbol) {
  final code = stripCppComments(cppSrc);
  return RegExp('$symbol\\s*\\(').hasMatch(code);
}

/// 主入口:纯函数审计。
///
/// [slamYamlSources] 键是给人看的名字(通常是路径),值是**slam** yaml 源文本
/// (不是 sensor yaml)。[managerCppSource] 是 XRSLAMManager.cpp 源文本。
ExtrinsicsAuditResult auditExtrinsicsSingleApplication({
  required Map<String, String> slamYamlSources,
  required String managerCppSource,
}) {
  final findings = <OutputExtrinsicFinding>[];
  final names = slamYamlSources.keys.toList()..sort();
  for (final name in names) {
    findings.add(parseOutputExtrinsic(name, slamYamlSources[name]!));
  }
  return ExtrinsicsAuditResult(
    interfaceAppliesCameraToBodyRotation: interfaceAppliesCall(
      managerCppSource,
      'camera_to_body_rotation',
    ),
    interfaceAppliesCameraToBodyTranslation: interfaceAppliesCall(
      managerCppSource,
      'camera_to_body_translation',
    ),
    findings: findings,
  );
}
