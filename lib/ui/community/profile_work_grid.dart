import 'package:flutter/material.dart';

import '../../community/community_service.dart';
import '../../community/feed_models.dart';
import '../design_system.dart';
import 'work_detail_page.dart';

class ProfileWorkGrid extends StatelessWidget {
  const ProfileWorkGrid({
    super.key,
    required this.works,
    required this.service,
    this.onWorkTap,
  });

  final List<FeedWork> works;
  final CommunityService? service;
  final ValueChanged<FeedWork>? onWorkTap;

  @override
  Widget build(BuildContext context) {
    if (works.isEmpty) return const SizedBox(height: 80);
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
        childAspectRatio: 1,
      ),
      itemCount: works.length,
      itemBuilder: (context, index) {
        final work = works[index];
        final path = work.thumbnailStoragePath;
        final url = path == null || service == null
            ? null
            : service!.thumbnailUrlFor(path);
        return InkWell(
          key: Key('profile-work-${work.id}'),
          borderRadius: BorderRadius.circular(AetherRadii.sm),
          onTap: () => _open(context, work),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AetherRadii.sm),
            child: ColoredBox(
              color: AetherColors.bgElevated,
              child: url == null
                  ? const Icon(
                      Icons.view_in_ar_outlined,
                      color: AetherColors.textTertiary,
                    )
                  : Image.network(
                      url,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const Icon(
                        Icons.view_in_ar_outlined,
                        color: AetherColors.textTertiary,
                      ),
                    ),
            ),
          ),
        );
      },
    );
  }

  void _open(BuildContext context, FeedWork work) {
    final callback = onWorkTap;
    if (callback != null) {
      callback(work);
      return;
    }
    final communityService = service;
    if (communityService == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WorkDetailPage(work: work, service: communityService),
      ),
    );
  }
}
