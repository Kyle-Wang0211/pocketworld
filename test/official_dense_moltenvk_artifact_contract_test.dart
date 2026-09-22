import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MoltenVK iOS device artifact is immutable and license-complete', () {
    const root =
        'vendor/official_dense/third_party/moltenvk-1.4.2-ios';
    final manifestFile = File('$root/artifact_manifest.json');
    final manifest =
        jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;

    expect(manifest['version'], '1.4.2');
    expect(
      manifest['upstream_commit'],
      'db66022459ffb663aa2b50f6b018bc2e124f5edf',
    );
    final release = manifest['release_asset'] as Map<String, dynamic>;
    expect(release['byte_count'], 34535424);
    expect(
      release['sha256'],
      'b5d947b1660e6e9fed40b9cd2387e160aaab9e80b775c0cef7e14059405178c1',
    );

    final selected = manifest['selected_artifact'] as Map<String, dynamic>;
    expect(selected['platform'], 'ios');
    expect(selected['architecture'], 'arm64');
    expect(selected['minimum_os_version'], '15.0');
    final library = File('$root/${selected['path']}');
    expect(library.lengthSync(), selected['byte_count']);
    expect(
      sha256.convert(library.readAsBytesSync()).toString(),
      selected['sha256'],
    );

    final infoPlist = File('$root/MoltenVK/MoltenVK.xcframework/Info.plist');
    expect(
      sha256.convert(infoPlist.readAsBytesSync()).toString(),
      manifest['xcframework_info_plist_sha256'],
    );
    expect(
      Directory('$root/MoltenVK/MoltenVK.xcframework')
          .listSync(recursive: true)
          .whereType<Directory>()
          .map((directory) => directory.path)
          .where((path) => path.contains('simulator')),
      isEmpty,
    );

    final license = manifest['license'] as Map<String, dynamic>;
    expect(license['spdx'], 'Apache-2.0');
    expect(
      sha256.convert(File('$root/${license['path']}').readAsBytesSync()).toString(),
      license['sha256'],
    );
    final notices =
        (manifest['distribution_notice_files'] as List)
            .cast<Map<String, dynamic>>();
    expect(notices, hasLength(5));
    for (final notice in notices) {
      expect(
        sha256
            .convert(File('$root/${notice['path']}').readAsBytesSync())
            .toString(),
        notice['sha256'],
      );
    }

    final files = Directory(root)
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path != manifestFile.path)
        .toList()
      ..sort((left, right) => left.path.compareTo(right.path));
    expect(files, hasLength(manifest['vendored_file_count_without_manifest']));
    final hashList = files
        .map(
          (file) =>
              '${sha256.convert(file.readAsBytesSync())}  ${file.path}\n',
        )
        .join();
    expect(
      sha256.convert(utf8.encode(hashList)).toString(),
      manifest['vendored_file_hash_list_sha256'],
    );
  });
}
