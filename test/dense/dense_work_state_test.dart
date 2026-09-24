// Build 174 — 「当用户点击下一步的时候，数据采集阶段就正式结束了」 (user 2026-09-24): whether a work entered
// the dense stage, read from its directory (survives a restart), and every entry back to capture or
// sparse reconstruction closed behind it. Pure checks + wiring anchors (code only, comments stripped);
// every judge has a negative control.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/dense/dense_work_state.dart';
import 'package:pocketworld_flutter/official_capture/selection_box.dart';

import '../point_cloud_lod/fake_lod_platform.dart' show writeDensePly;

String code(String path) => File(path)
    .readAsStringSync()
    .split('\n')
    .map((l) {
      final i = l.indexOf('//');
      return i < 0 ? l : l.substring(0, i);
    })
    .join('\n');

String bodyOf(String src, String signature) {
  final a = src.indexOf(signature);
  expect(a, greaterThan(-1), reason: 'not found: $signature');
  final b = src.indexOf('\n}\n', a);
  return src.substring(a, b < 0 ? src.length : b);
}

void main() {
  late Directory work;
  setUp(() => work = Directory.systemTemp.createTempSync('dense_work_state'));
  tearDown(() => work.deleteSync(recursive: true));

  const box = SelectionBox(cx: 1, cy: 2, cz: 3, sx: 0.4, sy: 0.5, sz: 0.6);

  group('state from the work directory', () {
    test('nothing ⇒ notStarted; capture entries open (NEGATIVE control of every case below)', () {
      File('${work.path}/official_sfm_sparse.ply').writeAsStringSync('sparse');
      File('${work.path}/$kSelectionBoxFileName').writeAsStringSync('{}');
      expect(denseWorkStateOf(work.path), DenseWorkState.notStarted);
      expect(denseStageEntered(work.path), isFalse);
      expect(recaptureBlockedReason(work.path), isNull);
    });

    test('the launcher marker ⇒ startedIncomplete (a restart still knows 下一步 was tapped)', () {
      writeDenseStartedMarker(work.path, selection: null, sparsePoints: 10);
      expect(denseWorkStateOf(work.path), DenseWorkState.startedIncomplete);
      expect(recaptureBlockedReason(work.path), contains('完成稠密'));
    });

    test('dense_work/ left by a killed run of an older build ⇒ startedIncomplete', () {
      Directory('${work.path}/$kDenseWorkDirName').createSync();
      expect(denseWorkStateOf(work.path), DenseWorkState.startedIncomplete);
    });

    test('an official_dense.ply cut short ⇒ startedIncomplete; complete ⇒ done', () {
      final ply = writeDensePly('${work.path}/$kDensePlyFileName', 500);
      final bytes = ply.readAsBytesSync();
      expect(denseWorkStateOf(work.path), DenseWorkState.done);
      expect(recaptureBlockedReason(work.path), contains('done'));
      ply.writeAsBytesSync(bytes.sublist(0, bytes.length - 15));
      expect(denseWorkStateOf(work.path), DenseWorkState.startedIncomplete);
      expect(denseStageEntered(work.path), isTrue);
    });
  });

  group('「完成稠密」 runs on the first run\'s selection', () {
    test('marker with a box ⇒ that box; marker with none ⇒ the whole cloud (even if a box is saved)', () async {
      writeDenseStartedMarker(work.path, selection: box, sparsePoints: 10);
      expect((await denseResumeSelection(work.path))?.toJson(), box.toJson());
      await box.copyWith(cx: 9).saveTo(work.path);
      expect((await denseResumeSelection(work.path))?.toJson(), box.toJson(), reason: 'the marker wins');
      writeDenseStartedMarker(work.path, selection: null, sparsePoints: 10);
      expect(await denseResumeSelection(work.path), isNull);
    });

    test('no marker (older build) ⇒ the box saved in the work directory', () async {
      await box.saveTo(work.path);
      expect((await denseResumeSelection(work.path))?.toJson(), box.toJson());
      File('${work.path}/$kSelectionBoxFileName').deleteSync();
      expect(await denseResumeSelection(work.path), isNull);
    });
  });

  test('the long-press menu gives 「开始训练 / 拍摄更多照片」 only before sparse AND before 下一步', () {
    expect(showRecaptureEntries(canViewSparse: false, denseEntered: false), isTrue);
    expect(showRecaptureEntries(canViewSparse: false, denseEntered: true), isFalse);
    expect(showRecaptureEntries(canViewSparse: true, denseEntered: false), isFalse);
    expect(showRecaptureEntries(canViewSparse: true, denseEntered: true), isFalse);
  });

  group('wiring (code, comments stripped)', () {
    test('every route back to capture / sparse reconstruction refuses a work that entered the dense stage', () {
      final routes = code('lib/ui/official_capture/official_gallery_routes.dart');
      for (final (sig, first, push) in [
        ('Future<void> pushOfficialResumeRoute(', "if (_refuseRecapture('resume/regenerate', captureDir)) return;", '_pushReconstructOnly('),
        ('Future<void> pushOfficialRebuildFromPhotosRoute(', "if (_refuseRecapture('rebuild-from-photos', captureDir)) return;", '_pushReconstructOnly('),
        ('Future<bool> pushOfficialExtendRoute(', "if (_refuseRecapture('extend (补拍)', captureDir)) return false;", 'OfficialARCapturePage(extendCaptureDir: captureDir)'),
      ]) {
        final body = bodyOf(routes, sig);
        final g = body.indexOf(first);
        final p = body.indexOf(push);
        expect(g, greaterThan(0), reason: sig);
        expect(p, greaterThan(g), reason: '$sig: the refusal comes before the push');
      }
      expect(bodyOf(routes, 'bool _refuseRecapture('), contains('recaptureBlockedReason(captureDir)'));
      // NEGATIVE: the finder does not match an absent guard
      expect(routes.contains("_refuseRecapture('something-else'"), isFalse);
    });

    test('the gallery card: menu entries and the resume offer check the dense stage', () {
      final me = code('lib/ui/me_page.dart');
      expect(me, contains('final denseEntered = captureDir != null && denseStageEntered(captureDir);'));
      expect(me, contains('if (showRecaptureEntries(\n                canViewSparse: canViewSparse,\n                denseEntered: denseEntered,\n              )) ...['));
      final offer = me.indexOf('case DraftCardAction.offerResume:');
      final guard = me.indexOf('if (captureDir != null && denseStageEntered(captureDir)) {', offer);
      final call = me.indexOf('await _offerResume(record, recoverableDir!);', offer);
      expect(offer, greaterThan(0));
      expect(guard > offer && guard < call, isTrue);
      // NEGATIVE: the old unconditional menu branch is gone
      expect(me.contains('if (!canViewSparse) ...['), isFalse);
    });

    test('the launcher records the start before the job; the pages lock 选区编辑 on it', () {
      final l = code('lib/dense/native_dense_stage_launcher.dart');
      final running = l.indexOf('_running = true;');
      final marker = l.indexOf('writeDenseStartedMarker(request.captureDir, selection: request.selection, sparsePoints: request.pointCount);');
      final job = l.indexOf('unawaited(_runJob(');
      expect(running > 0 && marker > running && job > marker, isTrue);
      final page = code('lib/ui/official_capture/ar_capture_page.dart');
      final edit = page.indexOf('onEnterEditing:');
      expect(page.indexOf('!_denseEnteredHere &&', edit), greaterThan(edit));
      expect(page.indexOf('!_denseEnteredHere &&', edit) - edit, lessThan(200));
      expect(page, contains("nextLabel: _denseEnteredHere && !_denseDoneHere ? '完成稠密' : null,"));
      final viewer = code('lib/ui/official_capture/sparse_cloud_viewer_page.dart');
      final button = viewer.indexOf("key: const ValueKey('viewer-enter-editing')");
      final lock = viewer.lastIndexOf('builder: (context, _, _) => _denseEnteredNow()', button);
      expect(lock, greaterThan(0));
      expect(button - lock, lessThan(400));
    });
  });
}
