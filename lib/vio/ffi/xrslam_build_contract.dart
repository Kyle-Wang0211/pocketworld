import 'dart:io';

/// One frozen algorithm/dependency contract shared by every mobile package.
abstract final class XrslamBuildContract {
  static const String xrslamRevision =
      '4beb1a942f33da9afbfae2d70e2c641cfc2bb675';
  static const String xrslamBuildPatchSha256 =
      'b98ed6aa689c9edaaac6da707d97592217d3f6caccc6df8c4d6961e2ee751de0';
  static const String destroyLifecyclePatchSha256 =
      '13592cb486f159217fa5ecf9ef2f9863be78cf599d42fb1757e34bd7d4bbb220';
  static const String opencvVersion = '4.0.1';
  static const String opencvRevision =
      'c9ad5779f2803dcc91a9938142209128d30b22d1';
  static const String opencvBuildPatchSha256 =
      '4041a1ac34b397679a04b733aa78bb1c37a25fcaf6a19c32e9563b0fd9159136';
  static const String ceresRevision =
      'e809cf0c2879f521078b4c9e6329390b42ecf722';
  static const String ceresVersion = '1.14.0';
  static const String eigenVersion = '3.3.7';
  static const String spdlogVersion = 'v1.3.1';
  static const String spdlogCompatibilityPatchSha256 =
      '1afb69176857159ad29e69d0abf3359576ebc091104278fee5fdeeff08e21adb';
  static const String yamlCppVersion = 'yaml-cpp-0.7.0';

  /// The official non-iOS algorithm branch is the cross-platform authority.
  static const bool xrslamIos = false;
  static const bool threading = false;
  static const List<String> compileFlags = <String>[
    '-ffp-contract=off',
    '-fno-fast-math',
    '-fchar8_t',
    '-Dceres=pw_xrslam_ceres_1_14',
  ];
}

/// Owns the two files consumed by generic XRSLAM's `YAML::LoadFile` path.
///
/// Dart creates the byte-exact inputs on every platform. Swift/Kotlin only
/// transport these paths to the same five-function C ABI.
final class XrslamRuntimeConfigFiles {
  XrslamRuntimeConfigFiles._({
    required this.directory,
    required this.slamFile,
    required this.deviceFile,
  });

  final Directory directory;
  final File slamFile;
  final File deviceFile;
  bool _disposed = false;

  static Future<XrslamRuntimeConfigFiles> materialize({
    required String slamYaml,
    required String deviceYaml,
  }) async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'pw_xrslam_generic_',
    );
    final File slamFile = File('${directory.path}/slam.yaml');
    final File deviceFile = File('${directory.path}/device.yaml');
    try {
      await slamFile.writeAsString(slamYaml, flush: true);
      await deviceFile.writeAsString(deviceYaml, flush: true);
      return XrslamRuntimeConfigFiles._(
        directory: directory,
        slamFile: slamFile,
        deviceFile: deviceFile,
      );
    } catch (_) {
      if (await directory.exists()) await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}
