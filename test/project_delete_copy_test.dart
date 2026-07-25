import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/l10n/app_localizations_en.dart';
import 'package:pocketworld_flutter/l10n/app_localizations_zh.dart';

void main() {
  test('project delete confirmation states permanent local data removal', () {
    final zh = AppL10nZh().meDeleteDialogContent('测试项目');
    expect(zh, contains('永久删除'));
    expect(zh, contains('原始照片'));
    expect(zh, contains('点云'));
    expect(zh, contains('无法恢复'));

    final en = AppL10nEn().meDeleteDialogContent('Test project');
    expect(en, contains('permanently delete'));
    expect(en, contains('original photos'));
    expect(en, contains('point cloud'));
    expect(en, contains('cannot be undone'));
  });
}
