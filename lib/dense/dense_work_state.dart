// dense_work_state.dart — where a work stands with respect to the dense stage, read from its directory
// (so it survives an app restart). Build 174, user 2026-09-24:
//   「永远不会重新训练稠密。如果有那就是 bug」
//   「补拍只适用于稀疏阶段呀!当用户点击下一步的时候就回不去了呀!就是用户点击下一步的时候，数据采集
//    阶段就正式结束了」
//
//   notStarted        no sign of a dense run: capture/sparse entries (补拍, 重建, 选区编辑, 下一步) as before
//   startedIncomplete a dense run began (下一步 was tapped) but no complete official_dense.ply: the only thing
//                     left to do is to finish the dense stage (「完成稠密」, same selection as the first run);
//                     no 补拍 / 重建 / sparse editing — that is not a re-training, it never completed
//   done              complete official_dense.ply (header count fills the file): never trained again
//
// Evidence that a run began, any one suffices: the marker written when the launcher starts a run
// (dense_started.json, from build 174), the dense_work/ scratch the job leaves behind when it is killed
// (older builds), or an official_dense.ply of any length (only the dense job writes that file).
import 'dart:convert';
import 'dart:io';

import '../official_capture/selection_box.dart';
import '../official_util/device_log.dart';
import '../point_cloud_lod/dense_lod_cache.dart' show densePlyComplete;

const String kDensePlyFileName = 'official_dense.ply';
const String kDenseWorkDirName = 'dense_work';

/// Written by the dense launcher the moment a run really starts (inputs gathered, job about to begin).
const String kDenseStartedMarkerName = 'dense_started.json';

enum DenseWorkState { notStarted, startedIncomplete, done }

DenseWorkState denseWorkStateOf(String captureDir) {
  final ply = '$captureDir/$kDensePlyFileName';
  if (densePlyComplete(ply)) return DenseWorkState.done;
  try {
    if (File('$captureDir/$kDenseStartedMarkerName').existsSync() ||
        Directory('$captureDir/$kDenseWorkDirName').existsSync() ||
        File(ply).existsSync()) {
      return DenseWorkState.startedIncomplete;
    }
  } catch (_) {}
  return DenseWorkState.notStarted;
}

/// 下一步 was tapped for this work at some point (running, killed, failed or done): the capture stage
/// is over — no 补拍, no 重建, no sparse editing.
bool denseStageEntered(String captureDir) => denseWorkStateOf(captureDir) != DenseWorkState.notStarted;

/// Why a capture/sparse entry (补拍, 继续/重新重建, 从照片重建) must not open for [captureDir], or null.
/// Routes and the gallery card call this before pushing anything.
String? recaptureBlockedReason(String captureDir) => switch (denseWorkStateOf(captureDir)) {
  DenseWorkState.notStarted => null,
  DenseWorkState.startedIncomplete => 'dense stage entered (下一步 tapped, not finished): only 完成稠密 is allowed',
  DenseWorkState.done => 'dense stage done: the capture stage is closed',
};

/// The long-press menu's 「开始训练 / 拍摄更多照片」 (both go back to capture or sparse): only for a work
/// that has no sparse cloud yet AND never entered the dense stage.
bool showRecaptureEntries({required bool canViewSparse, required bool denseEntered}) =>
    !canViewSparse && !denseEntered;

/// The launcher's record of a run that starts. Never deleted: it is the proof, after a restart, that
/// the capture stage is over. [selection] = the box the run was asked for (null = the whole cloud), so
/// 「完成稠密」 later runs on the same selection.
void writeDenseStartedMarker(String captureDir, {required SelectionBox? selection, required int sparsePoints}) {
  try {
    final f = File('$captureDir/$kDenseStartedMarkerName');
    f.writeAsStringSync(
      jsonEncode(<String, Object?>{
        'schema': 'pw_dense_started/1',
        'started_at': DateTime.now().toIso8601String(),
        'sparse_points': sparsePoints,
        'selection': selection?.toJson(),
      }),
      flush: true,
    );
  } catch (e) {
    // The job still runs; dense_work/ (made by the job) remains as evidence if it is killed.
    DeviceLog.log('DenseStage', 'could not write $kDenseStartedMarkerName: $e');
  }
}

/// The selection to finish an interrupted dense run with: the marker's (what the first run was asked
/// for); for a run started by a build without the marker, the box saved in the work directory.
Future<SelectionBox?> denseResumeSelection(String captureDir) async {
  try {
    final f = File('$captureDir/$kDenseStartedMarkerName');
    if (f.existsSync()) {
      final j = jsonDecode(f.readAsStringSync());
      if (j is Map) return SelectionBox.fromJson(j['selection']);
    }
  } catch (_) {}
  return SelectionBox.loadFrom(captureDir);
}
