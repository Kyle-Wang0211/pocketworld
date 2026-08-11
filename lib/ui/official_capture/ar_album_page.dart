// Full-screen photo album for the RealityScan-style AR capture flow.
//
// Replaces the dome capture page's modal bottom-sheet photo tray with a
// dedicated full-screen page: a time-ordered grid of every verified project
// photo, tap-to-enlarge, per-photo delete, and a back button. Reads its list
// from the live [OfficialProjectPhotoAlbum] so ring-buffer curation and SfM
// queue state can never alter the user-visible count.
//
// Cross-platform note: this is pure Flutter/Dart (no platform channels), so
// it ports as-is to Android / HarmonyOS capture flows.

import 'dart:io';

import 'package:flutter/material.dart';

import '../../official_capture/photo_card_state.dart';
import '../../official_capture/project_photo_album.dart';

class ARAlbumPage extends StatefulWidget {
  const ARAlbumPage({
    super.key,
    required this.projectPhotos,
    required this.onDelete,
  });

  /// The authoritative set of successfully verified 12MP project photos.
  final OfficialProjectPhotoAlbum projectPhotos;

  /// Deletes the photo at [path] (disk files + retained list) and updates
  /// the owning capture page. Provided by the capture page so deletion stays
  /// consistent with the live count + AR cards.
  final Future<void> Function(String path) onDelete;

  @override
  State<ARAlbumPage> createState() => _ARAlbumPageState();
}

class _ARAlbumPageState extends State<ARAlbumPage> {
  static const Color _bg = Color(0xFF111113);
  final Set<String> _selected = <String>{};
  bool _selecting = false;

  @override
  void initState() {
    super.initState();
    widget.projectPhotos.addListener(_onStoreChanged);
  }

  @override
  void dispose() {
    widget.projectPhotos.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  /// Verified photos ordered by their frame-exact ARKit capture timestamp,
  /// newest first.
  List<OfficialProjectPhoto> _orderedPhotos() {
    final entries =
        widget.projectPhotos.photos
            .where((photo) => File(photo.jpegPath).existsSync())
            .toList(growable: false)
          ..sort((a, b) => b.captureTimestamp.compareTo(a.captureTimestamp));
    return entries;
  }

  /// Opens the full-screen swipeable pager starting at [index] within the
  /// current [_orderedPhotos] snapshot. Left/right swipe moves between adjacent
  /// photos; deleting advances to the neighbour (see [_PhotoPagerView]). The
  /// grid refreshes on close (and live, via the projectPhotos listener) to
  /// reflect any deletions.
  Future<void> _openFullScreen(int index) async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      builder: (ctx) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: _PhotoPagerView(
          initialIndex: index,
          photos: _orderedPhotos(),
          onDelete: widget.onDelete,
          onRetake: () {
            Navigator.of(ctx).pop();
            Navigator.of(context).pop();
          },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  void _toggleSelection(String path) {
    setState(() {
      _selecting = true;
      if (!_selected.add(path)) _selected.remove(path);
      if (_selected.isEmpty) _selecting = false;
    });
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除所选照片？'),
        content: Text(
          '将从相册、磁盘和当前重建中删除 ${_selected.length} 张照片。'
          '只有你确认后才会执行。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除所选'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final selected = List<String>.of(_selected);
    for (final path in selected) {
      await widget.onDelete(path);
    }
    if (!mounted) return;
    setState(() {
      _selected.removeWhere(
        (path) => !widget.projectPhotos.paths.contains(path),
      );
      _selecting = _selected.isNotEmpty;
    });
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
          widget.projectPhotos.disconnectedCount > 0
              ? '已收集 ${photos.length} 张 · '
                    '${widget.projectPhotos.disconnectedCount} 未连接'
              : '已收集 ${photos.length} 张',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          if (_selecting)
            TextButton(
              onPressed: _selected.isEmpty ? null : _deleteSelected,
              child: Text(
                '删除所选(${_selected.length})',
                style: const TextStyle(color: Color(0xFFFF5A5F)),
              ),
            )
          else
            TextButton(
              onPressed: photos.isEmpty
                  ? null
                  : () => setState(() => _selecting = true),
              child: const Text('选择', style: TextStyle(color: Colors.white)),
            ),
        ],
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
                  final photo = photos[index];
                  return _AlbumTile(
                    index: index,
                    photo: photo,
                    selected: _selected.contains(photo.jpegPath),
                    selecting: _selecting,
                    onOpen: () {
                      if (_selecting) {
                        _toggleSelection(photo.jpegPath);
                      } else {
                        _openFullScreen(index);
                      }
                    },
                    onLongPress: () => _toggleSelection(photo.jpegPath),
                  );
                },
              ),
      ),
    );
  }
}

/// Full-screen, swipeable photo viewer used by [ARAlbumPage].
///
/// Holds a local, mutable copy of the album snapshot so left/right paging and
/// per-photo deletion stay responsive without a round-trip through the capture
/// store. Deleting the current photo advances to the neighbour (falling back to
/// the previous one when the last photo is removed); deleting the final photo
/// pops the pager back to the grid. The owning [ARAlbumPage] grid refreshes
/// independently via its own projectPhotos listener.
class _PhotoPagerView extends StatefulWidget {
  const _PhotoPagerView({
    required this.initialIndex,
    required this.photos,
    required this.onDelete,
    required this.onRetake,
  });

  final int initialIndex;
  final List<OfficialProjectPhoto> photos;
  final Future<void> Function(String path) onDelete;
  final VoidCallback onRetake;

  @override
  State<_PhotoPagerView> createState() => _PhotoPagerViewState();
}

class _PhotoPagerViewState extends State<_PhotoPagerView> {
  late final PageController _controller;
  late final List<OfficialProjectPhoto> _photos;
  late int _index;

  @override
  void initState() {
    super.initState();
    _photos = List<OfficialProjectPhoto>.of(widget.photos);
    _index = widget.initialIndex.clamp(0, _photos.length - 1);
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _deleteCurrent() async {
    final removeIdx = _index;
    final path = _photos[removeIdx].jpegPath;
    await widget.onDelete(path);
    if (!mounted) return;
    if (File(path).existsSync()) {
      // Deletion can be refused if live SfM is in an indivisible native step.
      return;
    }

    // Last remaining photo removed → close the pager, back to the grid.
    if (_photos.length <= 1) {
      Navigator.of(context).maybePop();
      return;
    }

    // When deleting the last page, step the controller back BEFORE itemCount
    // shrinks so PageView never renders an out-of-range page.
    final removingLast = removeIdx == _photos.length - 1;
    if (removingLast) {
      _controller.jumpToPage(removeIdx - 1);
    }
    setState(() {
      _photos.removeAt(removeIdx);
      // Middle page: stay on the same slot so the next photo slides in.
      // Last page: fall back to the new last photo.
      _index = removingLast ? removeIdx - 1 : removeIdx;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: PageView.builder(
            controller: _controller,
            itemCount: _photos.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (ctx, i) => InteractiveViewer(
              minScale: 0.8,
              maxScale: 4,
              child: Center(
                child: Image.file(
                  File(_photos[i].jpegPath),
                  fit: BoxFit.contain,
                  cacheWidth: 1600,
                ),
              ),
            ),
          ),
        ),
        // Page indicator, e.g. "3 / 12".
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Center(
                child: Text(
                  '${_index + 1} / ${_photos.length}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 54,
          left: 0,
          right: 0,
          child: SafeArea(
            child: Center(
              child: _PhotoStatePill(state: _photos[_index].analysisState),
            ),
          ),
        ),
        Positioned(
          top: 0,
          right: 0,
          child: SafeArea(
            child: IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.close_rounded, color: Colors.white),
            ),
          ),
        ),
        // Delete the current photo, then advance to the neighbour.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: widget.onRetake,
                    icon: const Icon(
                      Icons.photo_camera_outlined,
                      color: Color(0xFFF5B821),
                    ),
                    label: const Text(
                      '返回补拍',
                      style: TextStyle(color: Color(0xFFF5B821), fontSize: 15),
                    ),
                    style: TextButton.styleFrom(
                      backgroundColor: Colors.black.withValues(alpha: 0.5),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 11,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  TextButton.icon(
                    onPressed: _deleteCurrent,
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
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _AlbumTile extends StatelessWidget {
  const _AlbumTile({
    required this.index,
    required this.photo,
    required this.selected,
    required this.selecting,
    required this.onOpen,
    required this.onLongPress,
  });

  final int index;
  final OfficialProjectPhoto photo;
  final bool selected;
  final bool selecting;
  final VoidCallback onOpen;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final stateColor = _photoStateColor(photo.analysisState);
    return GestureDetector(
      onTap: onOpen,
      onLongPress: onLongPress,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? const Color(0xFF2F97FF) : stateColor,
            width: selected ? 4 : 3,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.file(
                File(photo.jpegPath),
                fit: BoxFit.cover,
                cacheWidth: 300,
              ),
              Positioned(
                left: 6,
                top: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.62),
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
              Positioned(
                left: 6,
                right: 6,
                bottom: 6,
                child: _PhotoStatePill(
                  state: photo.analysisState,
                  compact: true,
                ),
              ),
              if (selecting)
                Positioned(
                  right: 6,
                  top: 6,
                  child: Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: selected ? const Color(0xFF2F97FF) : Colors.white,
                    size: 22,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

Color _photoStateColor(PhotoCardSfmState state) => switch (state) {
  PhotoCardSfmState.pending => Colors.black,
  PhotoCardSfmState.registered => Colors.white,
  PhotoCardSfmState.disconnected => const Color(0xFFFF3B45),
  PhotoCardSfmState.lowParallax => const Color(0xFFFFC53D),
};

String _photoStateLabel(PhotoCardSfmState state) => switch (state) {
  PhotoCardSfmState.pending => '处理中',
  PhotoCardSfmState.registered => '已连接',
  PhotoCardSfmState.disconnected => '未连接',
  PhotoCardSfmState.lowParallax => '低视差（PocketWorld 辅助提示）',
};

class _PhotoStatePill extends StatelessWidget {
  const _PhotoStatePill({required this.state, this.compact = false});

  final PhotoCardSfmState state;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = _photoStateColor(state);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 10,
        vertical: compact ? 3 : 5,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.68),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color, width: 1.3),
      ),
      child: Text(
        _photoStateLabel(state),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: state == PhotoCardSfmState.pending ? Colors.white : color,
          fontSize: compact ? 9 : 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
