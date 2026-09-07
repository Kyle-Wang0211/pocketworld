import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../community/report_evidence_processor.dart';
import '../../community/social_profile_models.dart';
import '../../community/social_profile_repository.dart';
import '../../l10n/app_localizations.dart';
import '../design_system.dart';

typedef EvidencePicker =
    Future<List<ReportEvidenceUpload>> Function(int remaining);

class UserReportPage extends StatefulWidget {
  const UserReportPage({
    super.key,
    required this.targetUserId,
    required this.repository,
    this.sourceWorkId,
    this.evidencePicker,
  });

  final String targetUserId;
  final String? sourceWorkId;
  final SocialProfileRepository repository;
  final EvidencePicker? evidencePicker;

  @override
  State<UserReportPage> createState() => _UserReportPageState();
}

class _UserReportPageState extends State<UserReportPage> {
  final TextEditingController _detail = TextEditingController();
  final ReportEvidenceProcessor _processor = const ReportEvidenceProcessor();
  UserReportReason? _reason;
  bool _showRightsReasons = false;
  ReportEvidenceKind _evidenceKind = ReportEvidenceKind.ownership;
  List<ReportEvidenceUpload> _evidence = const [];
  bool _busy = false;

  @override
  void dispose() {
    _detail.dispose();
    super.dispose();
  }

  Future<List<ReportEvidenceUpload>> _pickEvidence(int remaining) async {
    final files = await ImagePicker().pickMultiImage(
      limit: remaining,
      requestFullMetadata: false,
    );
    final uploads = <ReportEvidenceUpload>[];
    for (final file in files.take(remaining)) {
      uploads.add(
        _processor.process(
          await file.readAsBytes(),
          kind: _reason?.kind == ReportKind.rights
              ? _evidenceKind
              : ReportEvidenceKind.context,
        ),
      );
    }
    return uploads;
  }

  Future<void> _addEvidence() async {
    final remaining = 3 - _evidence.length;
    if (remaining <= 0 || _busy) return;
    try {
      final picker = widget.evidencePicker ?? _pickEvidence;
      final picked = await picker(remaining);
      if (!mounted || picked.isEmpty) return;
      setState(() => _evidence = [..._evidence, ...picked.take(remaining)]);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).reportImageProcessFailed)),
      );
    }
  }

  Future<void> _submit() async {
    final reason = _reason;
    if (reason == null || _busy) return;
    setState(() => _busy = true);
    try {
      final result = await widget.repository.reportUser(
        UserReportDraft(
          targetUserId: widget.targetUserId,
          reason: reason,
          detail: _detail.text,
          sourceWorkId: widget.sourceWorkId,
          evidence: _evidence,
        ),
      );
      if (!mounted) return;
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop(result);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.failedEvidenceCount == 0
                  ? AppL10n.of(context).reportUserSubmitted
                  : AppL10n.of(context).reportSubmittedPartial,
            ),
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(AppL10n.of(context).reportFailed)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _goBack() {
    if (_reason != null) {
      final wasRightsComplaint = _reason!.kind == ReportKind.rights;
      setState(() {
        _reason = null;
        _detail.clear();
        _evidence = const [];
        _showRightsReasons = wasRightsComplaint;
      });
    } else if (_showRightsReasons) {
      setState(() => _showRightsReasons = false);
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Scaffold(
      backgroundColor: AetherColors.bgCanvas,
      appBar: AppBar(
        backgroundColor: AetherColors.bgCanvas,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          onPressed: _goBack,
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
        ),
        title: Text(
          _reason != null
              ? l.reportAdditionalInfoTitle
              : _showRightsReasons
              ? l.reportRightsTitle
              : widget.sourceWorkId != null
              ? l.reportSheetTitle
              : l.reportUserTitle,
        ),
      ),
      body: _reason != null
          ? _detailStep(_reason!, l)
          : _showRightsReasons
          ? _reasonList(ReportKind.rights, l)
          : _topLevelReasonList(l),
    );
  }

  Widget _topLevelReasonList(AppL10n l) {
    final reasons = UserReportReason.values
        .where((reason) => reason.kind == ReportKind.standard)
        .toList(growable: false);
    return ListView.separated(
      itemCount: reasons.length + 1,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, color: AetherColors.border),
      itemBuilder: (context, index) {
        if (index == reasons.length) {
          return ListTile(
            minTileHeight: 72,
            leading: const Icon(Icons.verified_user_outlined),
            title: Text(l.reportRightsEntry, style: AetherTextStyles.h3),
            subtitle: Text(l.reportRightsSubtitle),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => setState(() => _showRightsReasons = true),
          );
        }
        return _reasonTile(reasons[index], l);
      },
    );
  }

  Widget _reasonList(ReportKind kind, AppL10n l) {
    final reasons = UserReportReason.values
        .where((reason) => reason.kind == kind)
        .toList(growable: false);
    return ListView.separated(
      itemCount: reasons.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, color: AetherColors.border),
      itemBuilder: (context, index) => _reasonTile(reasons[index], l),
    );
  }

  Widget _reasonTile(UserReportReason reason, AppL10n l) => ListTile(
    minTileHeight: 64,
    title: Text(_reasonLabel(reason, l), style: AetherTextStyles.h3),
    trailing: const Icon(Icons.chevron_right_rounded),
    onTap: () => setState(() {
      _reason = reason;
      _evidence = const [];
      _evidenceKind = reason.kind == ReportKind.rights
          ? ReportEvidenceKind.ownership
          : ReportEvidenceKind.context;
    }),
  );

  Widget _detailStep(UserReportReason reason, AppL10n l) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 20, 20, 120),
    children: [
      Text(_reasonLabel(reason, l), style: AetherTextStyles.h2),
      const SizedBox(height: 20),
      TextField(
        controller: _detail,
        minLines: 5,
        maxLines: 8,
        maxLength: reason.kind.maxDetailGraphemes,
        decoration: InputDecoration(
          hintText: reason.kind == ReportKind.standard
              ? l.reportStandardDetailHint
              : l.reportRightsDetailHint,
          border: const OutlineInputBorder(),
        ),
      ),
      if (widget.sourceWorkId != null) ...[
        const SizedBox(height: 12),
        InputChip(
          label: Text(l.reportSourceWork(widget.sourceWorkId!)),
          onPressed: null,
        ),
      ],
      const SizedBox(height: 20),
      if (reason.allowsEvidenceUpload) ...[
        Text(l.reportEvidenceOptional, style: AetherTextStyles.h3),
        const SizedBox(height: 4),
        Text(l.reportEvidenceLimitHint, style: AetherTextStyles.bodySm),
        const SizedBox(height: 12),
        if (reason.kind == ReportKind.rights) ...[
          DropdownButtonFormField<ReportEvidenceKind>(
            initialValue: _evidenceKind,
            decoration: InputDecoration(
              labelText: l.reportEvidenceType,
              border: const OutlineInputBorder(),
            ),
            items: ReportEvidenceKind.values
                .where((kind) => kind != ReportEvidenceKind.context)
                .map(
                  (kind) => DropdownMenuItem(
                    value: kind,
                    child: Text(_evidenceKindLabel(kind, l)),
                  ),
                )
                .toList(growable: false),
            onChanged: _busy
                ? null
                : (kind) {
                    if (kind != null) setState(() => _evidenceKind = kind);
                  },
          ),
          const SizedBox(height: 12),
        ],
        OutlinedButton.icon(
          onPressed: _evidence.length >= 3 ? null : _addEvidence,
          icon: const Icon(Icons.add_photo_alternate_outlined),
          label: Text(l.reportAddEvidence),
        ),
        if (_evidence.isNotEmpty) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 88,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _evidence.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) => Stack(
                children: [
                  ClipRRect(
                    key: Key('report-evidence-$index'),
                    borderRadius: BorderRadius.circular(AetherRadii.sm),
                    child: Image.memory(
                      _evidence[index].bytes,
                      width: 88,
                      height: 88,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox(
                        width: 88,
                        height: 88,
                        child: ColoredBox(color: AetherColors.bgElevated),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    top: 0,
                    child: IconButton.filled(
                      visualDensity: VisualDensity.compact,
                      iconSize: 16,
                      onPressed: () => setState(() {
                        _evidence = [
                          for (var i = 0; i < _evidence.length; i++)
                            if (i != index) _evidence[i],
                        ];
                      }),
                      icon: const Icon(Icons.close),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ] else
        Text(l.reportSensitiveEvidenceWarning, style: AetherTextStyles.bodySm),
      const SizedBox(height: 28),
      FilledButton(
        onPressed: _busy ? null : _submit,
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          backgroundColor: AetherColors.primary,
          foregroundColor: Colors.white,
        ),
        child: Text(_busy ? l.reportSubmitting : l.reportSubmitUser),
      ),
    ],
  );

  String _reasonLabel(UserReportReason reason, AppL10n l) => switch (reason) {
    UserReportReason.impersonation => l.reportReasonImpersonation,
    UserReportReason.harassmentThreat => l.reportReasonHarassmentThreat,
    UserReportReason.spamFraud => l.reportReasonSpamFraud,
    UserReportReason.minorSafety => l.reportReasonMinorSafety,
    UserReportReason.sexualContent => l.reportReasonSexualLowQuality,
    UserReportReason.violenceIllegal => l.reportReasonViolenceIllegal,
    UserReportReason.misinformation => l.reportReasonMisleading,
    UserReportReason.privacyIp => l.reportReasonPrivacyIp,
    UserReportReason.other => l.reportReasonOtherUncertain,
  };

  String _evidenceKindLabel(ReportEvidenceKind kind, AppL10n l) =>
      switch (kind) {
        ReportEvidenceKind.context => l.reportEvidenceContext,
        ReportEvidenceKind.identity => l.reportEvidenceIdentity,
        ReportEvidenceKind.ownership => l.reportEvidenceOwnership,
        ReportEvidenceKind.authorization => l.reportEvidenceAuthorization,
        ReportEvidenceKind.other => l.reportEvidenceOther,
      };
}
