import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// [2026-09-23 声明载体普查] 这组闸是为一个真实缺口加的。
///
/// Filament 经 thermion 静态链进出货包(iOS arm64 的
/// thermion_dart.framework 7,598,928 字节 / 5,394 个 filament 符号),
/// 但它的 Apache-2.0 署名此前在**每一个**声明载体里都是零命中 ——
/// THIRD_PARTY_NOTICES、Flutter 自动生成的 NOTICES.Z、CocoaPods
/// acknowledgements、Runner.app 资源、三个 vendored 许可目录,全零。
/// 根因是 Flutter 只会自动聚合 **Dart 包**的 LICENSE,不碰原生预编译库,
/// 而 thermion 上游的 Filament 预编译 zip 本身不带任何许可文件。
///
/// 下面第一条是结构闸(能对"路径写了但文件不在 / 文件在但目录没进 assets"
/// 报警),第二条是组件闸(能对"组件被删掉或版本被改了却没更新声明"报警)。
void main() {
  final notices = File('THIRD_PARTY_NOTICES').readAsStringSync();
  final pubspec = File('pubspec.yaml').readAsStringSync();

  /// pubspec 的 `flutter: assets:` 块里**真正生效**的条目。
  ///
  /// 不能用 `pubspec.contains('assets/licenses/')` —— 注释掉的行和散文注释里
  /// 的路径都会命中,闸就废了(这条是负对照 NC1 当场打出来的)。
  final declaredAssets = () {
    final entries = <String>{};
    var inAssets = false;
    for (final line in pubspec.split('\n')) {
      if (RegExp(r'^\s{2}assets:\s*$').hasMatch(line)) {
        inAssets = true;
        continue;
      }
      if (!inAssets) continue;
      if (line.trim().isEmpty || line.startsWith('#')) continue;
      // 块结束:回到两格及以内的键。
      if (RegExp(r'^\s{0,2}\S').hasMatch(line) &&
          !RegExp(r'^\s*-').hasMatch(line)) {
        inAssets = false;
        continue;
      }
      final entry = RegExp(r'^\s+-\s+(\S+)\s*$').firstMatch(line);
      if (entry != null) entries.add(entry.group(1)!);
    }
    return entries;
  }();

  test('every bundled license path in THIRD_PARTY_NOTICES actually ships', () {
    // "Bundled license: <path>", or a "Bundled licenses:" list that wraps onto
    // following lines. A wrapped list only continues while the line it is
    // continuing from ends in "," or "and" — that is the file's existing
    // convention (see the Highway and Lepton entries), and relying on it keeps
    // this parser from swallowing the unrelated lines that follow an entry.
    final referenced = <String>{};
    final lines = notices.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final start = RegExp(r'^Bundled licenses?:\s*(.*)$').firstMatch(lines[i]);
      if (start == null) continue;
      var buffer = start.group(1)!;
      var cursor = i;
      while (RegExp(r'(,|\band)$').hasMatch(buffer.trimRight()) &&
          cursor + 1 < lines.length) {
        cursor += 1;
        buffer = '$buffer ${lines[cursor]}';
      }
      for (final raw in buffer.split(RegExp(r'[,\s]+and\s+|,\s*|\s+'))) {
        final path = raw.trim().replaceAll(RegExp(r'[.,)]+$'), '');
        if (path.contains('/') && !path.startsWith('http')) {
          referenced.add(path);
        }
      }
    }

    expect(
      referenced.length,
      greaterThanOrEqualTo(30),
      reason: 'sanity check on the parse, not on the content',
    );

    final missingFile = <String>[];
    final notAnAsset = <String>[];
    for (final path in referenced) {
      if (!File(path).existsSync() || File(path).lengthSync() == 0) {
        missingFile.add(path);
        continue;
      }
      // 声明的文件必须真的进包:要么整个目录在 assets 里,要么文件自己在。
      final directory = '${path.substring(0, path.lastIndexOf('/'))}/';
      if (!declaredAssets.contains(directory) &&
          !declaredAssets.contains(path)) {
        notAnAsset.add(path);
      }
    }

    expect(
      missingFile,
      isEmpty,
      reason: 'THIRD_PARTY_NOTICES points at license texts that do not exist',
    );
    expect(
      notAnAsset,
      isEmpty,
      reason: 'license texts exist but are not declared as Flutter assets, so '
          'they never reach the device',
    );
  });

  test('components that ship but carry no Dart LICENSE are named with a pin', () {
    // 每条:组件名、一个只有查过上游才写得出的钉子、它的许可正文。
    const expectations = <String, List<String>>{
      'Filament': [
        'dee94b56db1518530a12de8fd7af1d3c05c3a680',
        'assets/licenses/filament-LICENSE',
      ],
      'Thermion': [
        'Copyright 2024 Nick Fisher',
        'assets/licenses/thermion-LICENSE',
      ],
      'XRSLAM': [
        '4beb1a942f33da9afbfae2d70e2c641cfc2bb675',
        'assets/licenses/xrslam-LICENSE',
      ],
      'OpenCV': [
        'd26b7dd99a879a62bd7ecdb08146b787252abdef',
        'assets/licenses/opencv-4.0.1-LICENSE',
      ],
      'Ceres Solver 1.14.0': [
        'aeebc66bd8ff5db65b852dac0cbac28f618ac5d8',
        'assets/licenses/ceres-1.14-LICENSE',
      ],
      'ONNX Runtime 1.15.1': [
        'microsoft/onnxruntime',
        'assets/licenses/onnxruntime-LICENSE',
      ],
      'MobileSAM': [
        '0d3b403339b4674a82493d5e97964dd78089ddc8',
        'assets/licenses/mobilesam-LICENSE',
      ],
    };

    for (final entry in expectations.entries) {
      expect(
        notices,
        contains(entry.key),
        reason: '${entry.key} ships but is not named in THIRD_PARTY_NOTICES',
      );
      for (final evidence in entry.value) {
        expect(
          notices,
          contains(evidence),
          reason: '${entry.key} is named but "$evidence" is missing',
        );
      }
    }
  });

  test('Filament ships only because thermion links it, so both are recorded', () {
    // 这条锁的是因果链:thermion 是 Dart 包(Flutter 会自动收它的 LICENSE),
    // Filament 是它下载的原生预编译库(Flutter 不会收)。任何一天 thermion
    // 被换掉或升级,这两条都必须一起复核。
    expect(pubspec, contains('thermion_flutter'));
    expect(notices, contains('Thermion and Google Filament'));
    expect(notices, contains('v1.58.0'));
    for (final vendored in const [
      'assets/licenses/filament-draco-LICENSE',
      'assets/licenses/filament-basisu-LICENSE',
      'assets/licenses/filament-basisu-zstd-LICENSE',
      'assets/licenses/filament-tinyexr-LICENSE',
      'assets/licenses/filament-meshoptimizer-LICENSE',
      'assets/licenses/filament-stb-LICENSE',
      'assets/licenses/filament-libpng-LICENSE',
      'assets/licenses/filament-libz-LICENSE',
    ]) {
      expect(notices, contains(vendored));
      expect(File(vendored).lengthSync(), greaterThan(0));
    }
  });

  test('the notices index itself is an asset, not just a repo file', () {
    // 这条是"第 4 条结构建议"的闸。在 2026-09-23 之前,THIRD_PARTY_NOTICES
    // 只是仓里的工程留档 —— 许可正文进了包,但"哪份正文属于哪个组件"这层
    // 映射在设备上根本不存在。
    expect(
      declaredAssets,
      contains('THIRD_PARTY_NOTICES'),
      reason: 'the notices index must ship, or the license texts that do ship '
          'have nothing that says what they belong to',
    );
  });

  test('the in-app licenses page is reachable from settings', () {
    final page =
        File('lib/ui/legal/open_source_licenses_page.dart').readAsStringSync();
    final settings = File('lib/ui/me_settings_page.dart').readAsStringSync();

    // 入口必须真的挂上,否则页面写了等于没写。
    expect(settings, contains('open_source_licenses_page.dart'));
    expect(settings, contains('OpenSourceLicensesPage.open(context)'));

    // 页面必须同时接上两条链:资产里的原生声明,和 Flutter 自动聚合的
    // pub 包声明(thermion 只在后者里)。
    expect(page, contains("const String kThirdPartyNoticesAsset = "
        "'THIRD_PARTY_NOTICES';"));
    expect(
      page,
      contains('showLicensePage'),
      reason: 'thermion and every other pub package are only ever recorded in '
          "Flutter's generated NOTICES blob; without showLicensePage nobody "
          'can read it',
    );

    // 页面列许可正文用的前缀,必须每条都真的是已声明的资产目录。
    // 注意取的是**常量声明**那一段:`kLicenseTextPrefixes` 这个名字在文件里
    // 出现两次(声明 + load() 里的使用),按名字 split 再取 .last 会落到
    // 后者上,拿到空清单 —— 这条是第一次跑就当场撞上的。
    final block = RegExp(
      r'kLicenseTextPrefixes = <String>\[(.*?)\];',
      dotAll: true,
    ).firstMatch(page);
    expect(block, isNotNull,
        reason: 'the page no longer declares kLicenseTextPrefixes');
    final prefixes = RegExp(r"'([^']+/)'")
        .allMatches(block!.group(1)!)
        .map((m) => m.group(1)!)
        .toList();
    expect(prefixes, isNotEmpty);
    for (final prefix in prefixes) {
      // 前缀只要能对上**某个**已声明的资产条目就算数:pubspec 里有的是整个
      // 目录(ios/Vendor/JXL/licenses/),有的是单个文件
      // (ios/Vendor/Zpaq/Zpaq-LICENSE.txt),两种都合法。要求前缀逐字等于
      // 目录条目会把后者误判成缺口 —— 这条是第一次跑就当场撞上的。
      expect(
        declaredAssets.any(
          (asset) => asset == prefix || asset.startsWith(prefix),
        ),
        isTrue,
        reason: 'the licenses page lists "$prefix" but pubspec ships nothing '
            'under it',
      );
    }
  });

  test('locally modified thermion files carry an Apache-2.0 4(b) notice', () {
    // 被改的文件不在版本控制里(副本在 ~/Developer/thermion_dart_pw),
    // 但让它可复现的 patch 在,所以闸挂在 patch 上:patch 里出现的每个
    // 文件都必须带那段头注。
    final patch =
        File('third_party/thermion_dart_0.3.4+1_pw.patch').readAsStringSync();
    final touched = RegExp(r'^\+\+\+ (thermion_dart_pw/\S+)', multiLine: true)
        .allMatches(patch)
        .map((m) => m.group(1)!)
        .toSet();

    expect(touched.length, 17, reason: 'the local patch touches 17 files');
    expect(
      'NOTICE OF MODIFICATION'.allMatches(patch).length,
      touched.length,
      reason: 'every file the patch modifies must gain the section 4(b) '
          'notice of modification, and the patch must be regenerated after '
          'the notices are added',
    );
  });
}
