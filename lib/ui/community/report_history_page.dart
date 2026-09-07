import 'package:flutter/material.dart';

import '../../community/social_profile_models.dart';
import '../../community/social_profile_repository.dart';
import '../../l10n/app_localizations.dart';
import '../design_system.dart';

class ReportHistoryPage extends StatefulWidget {
  const ReportHistoryPage({super.key, required this.repository});

  final SocialProfileRepository repository;

  @override
  State<ReportHistoryPage> createState() => _ReportHistoryPageState();
}

class _ReportHistoryPageState extends State<ReportHistoryPage> {
  List<ReportHistoryItem>? _reports;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final reports = await widget.repository.fetchMyReports();
      if (mounted) setState(() => _reports = reports);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Scaffold(
      backgroundColor: AetherColors.bg,
      appBar: AppBar(
        backgroundColor: AetherColors.bg,
        surfaceTintColor: Colors.transparent,
        title: Text(l.reportHistoryTitle),
      ),
      body: _failed
          ? _Message(
              text: l.reportHistoryLoadFailed,
              action: l.communityRetry,
              onTap: _load,
            )
          : _reports == null
          ? const Center(child: CircularProgressIndicator())
          : _reports!.isEmpty
          ? _Message(text: l.reportHistoryEmpty)
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                padding: const EdgeInsets.all(AetherSpacing.lg),
                itemCount: _reports!.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(height: AetherSpacing.md),
                itemBuilder: (_, index) =>
                    _ReportCard(report: _reports![index], l: l),
              ),
            ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  const _ReportCard({required this.report, required this.l});
  final ReportHistoryItem report;
  final AppL10n l;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(AetherSpacing.lg),
    decoration: BoxDecoration(
      color: AetherColors.bgCanvas,
      borderRadius: BorderRadius.circular(AetherRadii.lg),
      border: Border.all(color: AetherColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _reasonLabel(report.reason, l),
                style: AetherTextStyles.h3,
              ),
            ),
            _StatusChip(status: report.status, l: l),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '${report.kind == ReportKind.standard ? l.reportStandardTitle : l.reportRightsTitle} · #${report.id}',
          style: AetherTextStyles.caption,
        ),
        if (report.sourceWorkTitle != null) ...[
          const SizedBox(height: 6),
          Text(l.reportHistorySource(report.sourceWorkTitle!)),
        ],
        if (report.reporterFeedback != null) ...[
          const SizedBox(height: 10),
          Text(report.reporterFeedback!, style: AetherTextStyles.body),
        ],
      ],
    ),
  );
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status, required this.l});
  final ReportStatus status;
  final AppL10n l;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: AetherColors.bgElevated,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Text(_statusLabel(status, l), style: AetherTextStyles.caption),
    ),
  );
}

class _Message extends StatelessWidget {
  const _Message({required this.text, this.action, this.onTap});
  final String text;
  final String? action;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(text, style: AetherTextStyles.bodySm),
        if (action != null && onTap != null)
          TextButton(onPressed: onTap, child: Text(action!)),
      ],
    ),
  );
}

String _statusLabel(ReportStatus status, AppL10n l) => switch (status) {
  ReportStatus.pending => l.reportStatusPending,
  ReportStatus.inReview => l.reportStatusInReview,
  ReportStatus.needsInfo => l.reportStatusNeedsInfo,
  ReportStatus.actioned => l.reportStatusActioned,
  ReportStatus.dismissed => l.reportStatusDismissed,
};

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
