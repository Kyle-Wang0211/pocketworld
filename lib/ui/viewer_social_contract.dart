import 'package:flutter/foundation.dart';

@immutable
class ViewerSocialPolicyContract {
  const ViewerSocialPolicyContract({
    this.schemaVersion = 'aether_viewer_social_policy_contract_v1',
    this.owner = 'Flutter/Dart',
    this.feedLiveMountThreshold = 0.3,
    this.feedMountDebounceMs = 150,
    this.feedUnmountDelayMs = 300000,
    this.feedThumbnailQuality = 'feedThumbnail',
    this.detailQuality = 'full',
  });

  final String schemaVersion;
  final String owner;
  final double feedLiveMountThreshold;
  final int feedMountDebounceMs;
  final int feedUnmountDelayMs;
  final String feedThumbnailQuality;
  final String detailQuality;

  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'owner': owner,
    'algorithm_executor_boundary': {
      'schemaVersion': 'aether_algorithm_executor_boundary_v1',
      'hardRule':
          'Dart sealed spec -> thin executor -> Dart report/audit -> next stage',
      'policyOwner': 'Flutter/Dart',
      'executorRole': 'thin_renderer_only',
      'dartOwns': [
        'feed ranking and ordering',
        'live viewer mount/unmount policy',
        'thumbnail/cache fallback policy',
        'model format detection and unsupported-format fallback',
        'viewer quality hint selection',
        'optimistic like state and rollback',
        'user-visible product state',
      ],
      'executorOwns': [
        'Metal/Dawn texture allocation',
        'GLB/PLY/SPZ draw calls',
        'GPU resource lifetime execution requested by Dart',
        'raw renderer errors',
      ],
      'executorMustNotOwn': [
        'feed ordering',
        'when a card becomes live',
        'which fallback UI is shown',
        'like count truth',
        'product navigation state',
      ],
    },
    'feed_policy': {
      'live_mount_threshold': feedLiveMountThreshold,
      'mount_debounce_ms': feedMountDebounceMs,
      'unmount_delay_ms': feedUnmountDelayMs,
      'thumbnail_quality': feedThumbnailQuality,
    },
    'detail_policy': {'viewer_quality': detailQuality},
    'social_policy': {
      'like_mode': 'optimistic_dart_state_with_service_rollback',
      'source_of_truth': 'CommunityService response',
    },
  };
}

const kViewerSocialPolicyContract = ViewerSocialPolicyContract();
