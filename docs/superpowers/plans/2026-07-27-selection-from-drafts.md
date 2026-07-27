# 草稿查看器选区入口 实现计划(单任务)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** 草稿点开的稀疏点云页面底部 = 等待页同款"保存草稿|下一步",下一步进 SelectionPage,返回刷新框回显。

**Architecture:** `_bottomButton` 提成共享组件 `SfmBottomActionButton`;查看器 body 改 Column(点云 Expanded + 按钮行);SelectionPage 零改动。

**Tech Stack:** Flutter/Dart。Spec:`docs/superpowers/specs/2026-07-27-selection-region-design.md` 增补节。

## Global Constraints

- 注释/文案中文;绝不 `git add -A`(共享脏树);`dart format` 改动文件;`flutter analyze lib/ test/` 零新增(基线 12);全量 `flutter test` 零新增失败(当前 211);flutter test 前台单实例(先 `pkill -f flutter_tester`);TDD;commit `-F 文件 </dev/null` 含 Co-Authored-By。
- ⚠️ testWidgets FakeAsync zone 里真实 dart:io Future 完不成 —— 一律用现有 helper `_pumpUntilRealAsyncSettles`(见 test/selection_page_test.dart,可复制)推进。

---

### Task 1: 共享底部按钮 + 查看器双按钮入口

**Files:**
- Modify: `lib/ui/official_capture/sfm_preview_overlay.dart`(`_bottomButton` → 公开组件)
- Modify: `lib/ui/official_capture/sparse_cloud_viewer_page.dart`
- Test: `test/sparse_cloud_viewer_selection_test.dart`(扩展)

**Interfaces:**
- Produces: `class SfmBottomActionButton extends StatelessWidget { const SfmBottomActionButton({super.key, required this.label, required this.filled, required this.onTap}); }`(sfm_preview_overlay.dart 顶层)
- Consumes: `SelectionPage({required Float32List xyz, required Uint8List rgb, required String captureDir})`;`SelectionBox.loadFrom(dir)`

- [ ] **Step 1: 扩展测试(先红)**

在 `test/sparse_cloud_viewer_selection_test.dart` 追加(imports 补 `selection_page.dart`、`sfm_preview_overlay.dart` 按需;复制 `_pumpUntilRealAsyncSettles` helper 进本文件供各用例用;既有两用例的 pump 方式保持不变):

```dart
  testWidgets('加载成功:底部出现 保存草稿|下一步 双按钮', (tester) async {
    final dir = await Directory.systemTemp.createTemp('viewer3');
    addTearDown(() => dir.delete(recursive: true));
    late final String ply;
    await tester.runAsync(() async {
      ply = await _writePly(dir);
    });
    await tester.pumpWidget(
      MaterialApp(home: SparseCloudViewerPage(plyPath: ply)),
    );
    await _pumpUntilRealAsyncSettles(tester);
    expect(find.text('保存草稿'), findsOneWidget);
    expect(find.text('下一步'), findsOneWidget);
  });

  testWidgets('加载失败:无双按钮', (tester) async {
    final dir = await Directory.systemTemp.createTemp('viewer4');
    addTearDown(() => dir.delete(recursive: true));
    await tester.pumpWidget(
      MaterialApp(
        home: SparseCloudViewerPage(plyPath: '${dir.path}/nope.ply'),
      ),
    );
    await _pumpUntilRealAsyncSettles(tester);
    expect(find.text('点云文件读取失败'), findsOneWidget);
    expect(find.text('下一步'), findsNothing);
  });

  testWidgets('下一步 push SelectionPage;返回后框回显刷新', (tester) async {
    final dir = await Directory.systemTemp.createTemp('viewer5');
    addTearDown(() => dir.delete(recursive: true));
    late final String ply;
    await tester.runAsync(() async {
      ply = await _writePly(dir); // 无 JSON:初始 selectionBox == null
    });
    await tester.pumpWidget(
      MaterialApp(home: SparseCloudViewerPage(plyPath: ply)),
    );
    await _pumpUntilRealAsyncSettles(tester);
    var view = tester.widget<SparseCloudView>(find.byType(SparseCloudView));
    expect(view.selectionBox, isNull);

    await tester.tap(find.text('下一步'));
    await _pumpUntilRealAsyncSettles(tester);
    expect(find.byType(SelectionPage), findsOneWidget);

    // SelectionPage 初始化会建初始盒;点其返回键 → flush 落盘 → pop 回查看器
    await tester.tap(find.byKey(const ValueKey('selection-back')));
    await _pumpUntilRealAsyncSettles(tester);
    expect(find.byType(SelectionPage), findsNothing);
    expect(find.byType(SparseCloudViewerPage), findsOneWidget);
    // 返回后查看器重新 loadFrom:回显不再是 null
    view = tester.widget<SparseCloudView>(find.byType(SparseCloudView));
    expect(view.selectionBox, isNotNull);
  });

  testWidgets('保存草稿 = pop 查看器', (tester) async {
    final dir = await Directory.systemTemp.createTemp('viewer6');
    addTearDown(() => dir.delete(recursive: true));
    late final String ply;
    await tester.runAsync(() async {
      ply = await _writePly(dir);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () => Navigator.of(ctx).push(
              MaterialPageRoute<void>(
                builder: (_) => SparseCloudViewerPage(plyPath: ply),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await _pumpUntilRealAsyncSettles(tester);
    await tester.tap(find.text('保存草稿'));
    await _pumpUntilRealAsyncSettles(tester);
    expect(find.byType(SparseCloudViewerPage), findsNothing);
  });
```

Run: `flutter test test/sparse_cloud_viewer_selection_test.dart` → 新用例 FAIL(无按钮/组件)。

- [ ] **Step 2: `_bottomButton` 提成公开组件**

`sfm_preview_overlay.dart`:新增顶层组件(样式逐字搬现 `_bottomButton` 方法体),三处调用点改 `SfmBottomActionButton(label: ..., filled: ..., onTap: ...)`,删私有方法:

```dart
/// 等待页/草稿查看器共用的底部动作按钮(保存草稿|下一步|完成 同款样式)。
/// [2026-07-27 增补] 草稿查看器复用同一形态 —— 两处必须同源,别再复制样式。
class SfmBottomActionButton extends StatelessWidget {
  const SfmBottomActionButton({
    super.key,
    required this.label,
    required this.filled,
    required this.onTap,
  });

  final String label;
  final bool filled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 13),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: filled ? Colors.white : const Color(0xFF2A2A2E),
          borderRadius: BorderRadius.circular(26),
          border: filled ? null : Border.all(color: Colors.white24),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: filled ? Colors.black : Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 3: 查看器接入双按钮 + 返回刷新**

`sparse_cloud_viewer_page.dart`:imports 补 `selection_page.dart`、`sfm_preview_overlay.dart` show SfmBottomActionButton;成功分支的 `Padding(SparseCloudView)` 改为:

```dart
            : Column(
                children: [
                  Expanded(
                    child: SparseCloudView(
                      xyz: cloud.xyz,
                      rgb: cloud.rgb,
                      selectionBox: _selectionBox,
                    ),
                  ),
                  // [2026-07-27 增补] 与等待页 refined 态完全同款的双按钮:
                  // 拍完进和草稿进,同一个"看稀疏点云的页面"长一个样(用户
                  // 签决:只加入口,其他什么都不变)。
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: SfmBottomActionButton(
                            label: '保存草稿',
                            filled: false,
                            // 本来就是草稿,无需写盘 —— 直接退回草稿列表。
                            onTap: () => Navigator.of(context).pop(),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: SfmBottomActionButton(
                            label: '下一步',
                            filled: true,
                            onTap: () => unawaited(_openSelection()),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
```

State 加方法(import `dart:async` 补 unawaited 如缺):

```dart
  /// 下一步 → 选区页(SelectionPage 零改动复用);返回后重读选区文件刷新
  /// 只读回显(用户刚改完的框和红点立刻可见)。pop 载荷 'save_draft' 在
  /// 此入口无退出动作,忽略即可。
  Future<void> _openSelection() async {
    final cloud = _cloud;
    if (cloud == null) return;
    await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => SelectionPage(
          xyz: cloud.xyz,
          rgb: cloud.rgb,
          captureDir: File(widget.plyPath).parent.path,
        ),
      ),
    );
    if (!mounted) return;
    final selBox = await SelectionBox.loadFrom(File(widget.plyPath).parent.path);
    if (!mounted) return;
    setState(() => _selectionBox = selBox);
  }
```

- [ ] **Step 4: 跑测试**

`pkill -f flutter_tester`;`flutter test test/sparse_cloud_viewer_selection_test.dart` 6/6 绿(2 旧+4 新);`flutter test test/sfm_preview_overlay_buttons_test.dart` 仍绿(组件提取无行为变化);全量 `flutter test` 零新增失败。

- [ ] **Step 5: format + analyze + 提交**

```bash
dart format lib/ui/official_capture/sfm_preview_overlay.dart lib/ui/official_capture/sparse_cloud_viewer_page.dart test/sparse_cloud_viewer_selection_test.dart
flutter analyze lib/ test/
git add lib/ui/official_capture/sfm_preview_overlay.dart lib/ui/official_capture/sparse_cloud_viewer_page.dart test/sparse_cloud_viewer_selection_test.dart
git commit -F <(printf 'feat(selection): 草稿查看器同款双按钮入口(保存草稿|下一步)\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>\n') </dev/null
```
