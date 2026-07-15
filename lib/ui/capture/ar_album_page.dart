// Full-screen photo album for the RealityScan-style AR capture flow.
//
// Replaces the dome capture page's modal bottom-sheet photo tray with a
// dedicated full-screen page: a time-ordered grid of every captured photo,
// tap-to-enlarge, per-photo delete, and a back button. Reads its list from
// the live capture-session inventory so it refreshes as photos
// are added or deleted while the capture session is still open.
//
// Cross-platform note: this is pure Flutter/Dart (no platform channels), so
// it ports as-is to Android / HarmonyOS capture flows.

import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

class ARAlbumPage extends StatefulWidget {
  const ARAlbumPage({
    super.key,
    required this.capturedPhotos,
    required this.onDelete,
  });

  /// User-owned photos committed in the current local capture.
  final ValueListenable<List<String>> capturedPhotos;

  /// Deletes the photo at [path] (disk files + retained list) and updates
  /// the owning capture page. Provided by the capture page so deletion stays
  /// consistent with the live count + AR cards.
  final Future<void> Function(String path) onDelete;

  @override
  State<ARAlbumPage> createState() => _ARAlbumPageState();
}

class _ARAlbumPageState extends State<ARAlbumPage> {
  static const Color _bg = Color(0xFF111113);

  @override
  void initState() {
    super.initState();
    widget.capturedPhotos.addListener(_onStoreChanged);
  }

  @override
  void dispose() {
    widget.capturedPhotos.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  /// Retained photos ordered by capture time, newest first.
  ///
  /// RealityScan orders its review grid chronologically; the JPEG path
  /// (`cell_<c>_slot_<s>.jpg`) sorts by dome cell, not time, so we order by
  /// file mtime instead — capture writes each still as it is shot, so mtime
  /// tracks shutter order closely enough for the album. (When per-photo
  /// timestamps from the `.json` sidecar are wired in, swap them in here.)
  List<String> _orderedPhotos() {
    final entries = <(String, DateTime)>[];
    for (final path in widget.capturedPhotos.value) {
      final file = File(path);
      if (!file.existsSync()) continue;
      DateTime mtime;
      try {
        mtime = file.lastModifiedSync();
      } on FileSystemException {
        mtime = DateTime.fromMillisecondsSinceEpoch(0);
      }
      entries.add((path, mtime));
    }
    entries.sort((a, b) => b.$2.compareTo(a.$2)); // newest first
    return entries.map((e) => e.$1).toList(growable: false);
  }

  Future<void> _openFullScreen(String path) async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      builder: (ctx) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 0.8,
                maxScale: 4,
                child: Center(
                  child: Image.file(
                    File(path),
                    fit: BoxFit.contain,
                    cacheWidth: 1600,
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: SafeArea(
                child: IconButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                ),
              ),
            ),
            // Delete this photo from the detail view, then close it.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: Center(
                    child: TextButton.icon(
                      onPressed: () async {
                        Navigator.of(ctx).pop();
                        await _deleteAt(path);
                      },
                      icon: const Icon(
                        Icons.delete_outline_rounded,
                        color: Colors.white,
                      ),
                      label: const Text(
                        '删除',
                        style: TextStyle(color: Colors.white, fontSize: 15),
                      ),
                      style: TextButton.styleFrom(
                        backgroundColor: Colors.black.withValues(alpha: 0.5),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 22,
                          vertical: 11,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteAt(String path) async {
    await widget.onDelete(path);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final photos = _orderedPhotos();
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          '已收集 ${photos.length} 张',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: photos.isEmpty
            ? const Center(
                child: Text(
                  '继续拍摄以收集照片',
                  style: TextStyle(color: Colors.white60, fontSize: 14),
                ),
              )
            : GridView.builder(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                ),
                itemCount: photos.length,
                itemBuilder: (ctx, index) {
                  final path = photos[index];
                  return _AlbumTile(
                    index: index,
                    path: path,
                    onOpen: () => _openFullScreen(path),
                  );
                },
              ),
      ),
    );
  }
}

class _AlbumTile extends StatelessWidget {
  const _AlbumTile({
    required this.index,
    required this.path,
    required this.onOpen,
  });

  final int index;
  final String path;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          onTap: onOpen,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(File(path), fit: BoxFit.cover, cacheWidth: 300),
          ),
        ),
        Positioned(
          left: 6,
          top: 6,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '${index + 1}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
