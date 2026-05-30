// MyWorkDetailPage — full-screen viewer for one of the user's OWN
// scans, plus the publish-to-community workflow.
//
// Three states the page handles:
//   • running — job is still queued/reconstructing/training/packaging.
//                Shows a spinner with the lifecycle status; no GLB yet.
//   • viewable — artifactPath points at a local file:// URL. Renders
//                LiveModelView (orbit on, manipulator drives camera).
//                "Publish" button is enabled.
//   • failed — job came back failed; shows reason + a retry-from-this-
//                record button (TODO; v1 just shows the message).
//
// Publish flow (Plan G W2 全本地 2026-05-16): community publish is
//   currently inert — the bottom sheet still collects title + description
//   but the confirm action shows "no cloud" snackbar. A future local-
//   first community story (local SQLite + nearby-share, etc.) will
//   replace the deleted PublishService.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../me/scan_record_store.dart';
import '../community/aether_cpp_card_demo.dart';
import '../design_system.dart';
import '../scan_record.dart';

class MyWorkDetailPage extends StatefulWidget {
  final String recordId;

  const MyWorkDetailPage({super.key, required this.recordId});

  @override
  State<MyWorkDetailPage> createState() => _MyWorkDetailPageState();
}

class _MyWorkDetailPageState extends State<MyWorkDetailPage> {
  late final ScanRecordStore _store = ScanRecordStore.instance;
  StreamSubscription<List<ScanRecord>>? _sub;
  ScanRecord? _record;

  @override
  void initState() {
    super.initState();
    _record = _store.byId(widget.recordId);
    _sub = _store.changes.listen((_) {
      final fresh = _store.byId(widget.recordId);
      if (mounted && fresh != null) setState(() => _record = fresh);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final r = _record;
    if (r == null) {
      return Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(backgroundColor: Colors.white, elevation: 0),
        body: Center(child: Text(l.meDetailRecordNotFound)),
      );
    }
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.chevron_left_rounded,
              color: AetherColors.textPrimary),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          r.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AetherColors.textPrimary,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(child: _buildBody(r)),
    );
  }

  Widget _buildBody(ScanRecord r) {
    final url = r.artifactPath;
    if (url == null) {
      // Plan G W2 全本地 (2026-05-16): no jobStatus / failureMessage /
      // pipelineStage anymore. "No artifact yet" = the local W3 pipeline
      // hasn't run on this capture's photos directory; show a generic
      // "processing" placeholder until W3 lands.
      return const _RunningState();
    }
    return AetherCppCardDemo(
      key: ValueKey('mywork-aether-${r.id}'),
      modelUrl: url,
      // Migrated 2026-05-02: detail page now runs the aether_cpp
      // path with interactive orbit + pinch — 1-finger drag rotates
      // the camera, 2-finger pinch zooms.
      interactive: true,
    );
  }
}

// Plan G W2 全本地 (2026-05-16): _PublishFormResult + _PublishForm +
// _PublishFormState were the community-publish bottom sheet, and
// _FailedState was the cloud-job failure splash. Both removed along
// with the upload chain. A future local-first community story will
// reintroduce a publish flow if needed.

class _RunningState extends StatelessWidget {
  const _RunningState();

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: AetherSpacing.md),
          Text(l.meDetailRunningProcessing, style: AetherTextStyles.bodySm),
        ],
      ),
    );
  }
}


