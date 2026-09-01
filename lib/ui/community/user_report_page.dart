import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

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
  List<ReportEvidenceUpload> _evidence = const [];
  bool _busy = false;

  @override
  void dispose() {
    _detail.dispose();
    super.dispose();
  }

  Future<List<ReportEvidenceUpload>> _pickEvidence(int remaining) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png'],
      allowMultiple: true,
      withData: true,
    );
    if (result == null) return const [];
    final uploads = <ReportEvidenceUpload>[];
    for (final file in result.files.take(remaining)) {
      final bytes =
          file.bytes ??
          (file.path == null ? null : await File(file.path!).readAsBytes());
      if (bytes == null) continue;
      uploads.add(_processor.process(bytes));
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
      setState(() {
        _evidence = [..._evidence, ...picked.take(remaining)];
      });
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

  @override
  Widget build(BuildContext context) {
    final reason = _reason;
    final l = AppL10n.of(context);
    return Scaffold(
      backgroundColor: AetherColors.bgCanvas,
      appBar: AppBar(
        backgroundColor: AetherColors.bgCanvas,
        surfaceTintColor: Colors.transparent,
        title: Text(
          reason == null ? l.reportUserTitle : l.reportAdditionalInfoTitle,
        ),
        leading: reason == null
            ? null
            : IconButton(
                onPressed: () => setState(() => _reason = null),
                icon: const Icon(Icons.arrow_back_ios_new_rounded),
              ),
      ),
      body: reason == null ? _reasonList(l) : _detailStep(reason, l),
    );
  }

  Widget _reasonList(AppL10n l) {
    return ListView.separated(
      itemCount: UserReportReason.values.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, color: AetherColors.border),
      itemBuilder: (context, index) {
        final reason = UserReportReason.values[index];
        return ListTile(
          minTileHeight: 64,
          title: Text(_reasonLabel(reason, l), style: AetherTextStyles.h3),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => setState(() {
            _reason = reason;
            _evidence = const [];
          }),
        );
      },
    );
  }

  Widget _detailStep(UserReportReason reason, AppL10n l) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 120),
      children: [
        Text(_reasonLabel(reason, l), style: AetherTextStyles.h2),
        const SizedBox(height: 20),
        TextField(
          controller: _detail,
          minLines: 5,
          maxLines: 8,
          maxLength: 500,
          decoration: InputDecoration(
            hintText: l.reportDetailUserHint,
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
          Text(
            l.reportSensitiveEvidenceWarning,
            style: AetherTextStyles.bodySm,
          ),
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
  }

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
}
