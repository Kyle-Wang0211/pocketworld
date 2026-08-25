// 把 XrslamConfigBuilder 真正生成的 YAML 打出来,用于与 host 探针逐字节对拍。
// 设备上 XRSLAMCreate 只返回 0/1,没有细节 —— 所以调试必须在 host 上做。
import 'dart:io';
import 'package:pocketworld_flutter/vio/ffi/xrslam_config.dart';

void main(List<String> args) {
  const CameraIntrinsics k = CameraIntrinsics(
    fx: 1000.0, fy: 1000.0, cx: 640.0, cy: 360.0,
    resolutionWidth: 1280, resolutionHeight: 720,
    provenance: FieldProvenance.placeholder,
  );
  const XrslamConfigBuilder b = XrslamConfigBuilder(intrinsics: k);
  final String out = args.isNotEmpty ? args.first : '/tmp/ydump';
  Directory(out).createSync(recursive: true);
  File('$out/device.yaml').writeAsStringSync(b.buildDeviceConfigYaml());
  File('$out/slam.yaml').writeAsStringSync(b.buildSlamConfigYaml());
  stdout.writeln('written to $out');
}
