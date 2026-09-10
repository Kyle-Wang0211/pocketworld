// photo_slot_naming.dart — 槽位照片文件名规则(纯 Dart,零依赖)。
//
// [2026-07-11 色彩污染修复] cap47 法医定案的独立大 bug:旧规则
// `cell_<i>_slot_<j>.jpg` 在重拍/驱逐同一槽位时**同名覆盖**文件内容,
// 而 SfM colorize 与 resume 按 fed jsonl 的 jpegPath(文件名)取色 ——
// 先喂入 SfM 的帧于是被"后来者的内容"染色(cap47 实测:cell_90/slot_1
// 被 6 个 frameId 先后覆盖,25/121 帧取错内容,16% 点色彩污染,
// var_gt40 暴涨 30×)。
//
// 新规则:文件名带 frameId 后缀 → 每次落盘都是**独立新文件**,fed jsonl
// 的 jpegPath 永远指向"喂入 SfM 那一刻"的真实内容。
//
// 唯一性依据:CaptureSession.start() 每次重建全新 captureDir 且
// _frameSeq 归零,frameId('tap-N'/'cap-N')在目录生命周期内单调唯一。
//
// 兼容性:所有消费方(colorize 解码、resume 的 basename 重join、
// photo_bundle manifest、相册、prune)都把文件名当不透明 path 用,
// 无一处反解 cell/slot;老采集的 fed jsonl 存的是旧式名,resume 按
// basename 原样重join,读旧名不崩。
//
// 磁盘:重拍的旧文件仍被 fed jsonl 引用(colorize/resume 要读),
// **不得**在新文件写成功后即删;由 colorize 之后的 deferred prune
// (retainOnlyCuratedPhotos / _prunePhotosAfterSparse)统一收尾。
//
// host 断言:tool/photo_slot_naming_check.dart(项目惯例,flutter test
// 在此 host 跑不了,纯 VM 能跑)。

/// 槽位照片的文件基名(不含扩展名):`cell_<i>_slot_<j>_<frameId>`。
/// `.jpg`(照片/preview)与 `.json`(AR sidecar)共用同一基名。
String photoSlotBaseName({
  required int cellIdx,
  required int slotIdx,
  required String frameId,
}) {
  return 'cell_${cellIdx}_slot_${slotIdx}_$frameId';
}

/// 已有照片文件名里最大的 frame 序号;没有可解析的名字则返回 0。
///
/// [2026-09-08 追加拍摄] 上面那条唯一性依据("start() 每次重建全新 captureDir
/// 且 _frameSeq 归零")在**补拍**下不再成立 —— 补拍复用同一个 captureDir。
/// 若序号仍从 0 起,新照片会和老照片同名,直接复现本文件开头记的那个 bug
/// (cap47:同名覆盖 → fed jsonl 的 jpegPath 指向"后来者的内容" → 25/121 帧
/// 取错颜色、16% 点色彩污染)。所以补拍必须把 _frameSeq 接到已有最大值之后。
///
/// 解析的是基名尾部的 `_tap-<N>` / `_cap-<N>`。两种前缀共用一个序号空间
/// (生产里 _frameSeq 本来就是同一个计数器),所以取两者的全局最大值。
/// 认不出的名字(老式 `cell_i_slot_j`、缩略图、任何第三方文件)一律记 0 而
/// 不是抛错 —— 一个陌生文件不该让补拍整个失败。
int maxFrameSeqInNames(Iterable<String> fileNames) {
  var maxSeq = 0;
  for (final name in fileNames) {
    final n = frameSeqInName(name);
    if (n != null && n > maxSeq) maxSeq = n;
  }
  return maxSeq;
}

/// 单个文件名里的 frame 序号;认不出返回 null。
///
/// [2026-09-08] 抽出来是因为它有了**第二个**用途:从存档照片重建时的**喂帧顺序**
/// (archived_photo_rebuild.dart)。那里不能按拍摄时刻排 —— ARKit 的 `t` 是
/// uptime 时钟,跨会话归零,而补拍天然跨会话。实测 cap_1788845271610360:
/// tap-1..182 的 t≈47901,补拍进来的 tap-203/226/233 t≈2145(晚 36 分钟、
/// 中间重启过),按 t 排会把补拍那三张排到最前面。
/// 而 N 由采集会话单调发放、补拍时由 [maxFrameSeqInNames] 接着往上排,
/// 所以它是我们自己保证的全局拍摄序,不依赖任何时钟。
///
/// 两个调用方共用这一处解析,避免"同一个规则两份实现"。
int? frameSeqInName(String fileName) {
  final m = RegExp(r'_(?:tap|cap)-(\d+)(?:\.[^.]*)?$').firstMatch(fileName);
  if (m == null) return null;
  return int.tryParse(m.group(1)!);
}
