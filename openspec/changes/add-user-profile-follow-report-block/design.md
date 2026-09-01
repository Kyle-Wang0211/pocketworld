# Design

## Client boundaries

`SocialProfileRepository` owns profile/follow/following/report/block queries and exposes immutable models. `UserProfilePage`, `FollowingListPage`, `UserReportPage`, and `BlockedUsersPage` depend on that interface so widget tests can use an in-memory fake. `VaultPage` remains the feed owner and only changes its author-tap navigation.

The external profile uses the existing `CommunityService.fetchPublicFeed(authorUserId: ...)` read path for its public work grid and the existing `WorkDetailPage` route for work viewing. No second work model or renderer is introduced.

## Follow and count invariants

The follow relation remains directional. Insert policy rejects either direction of an existing block. The block trigger deletes both directions of follows. A narrow `get_my_following` security-definer RPC returns only the caller's followed-account safe projection, including private profiles already followed, without weakening the general profile-read policy. `profiles.works_count` is redefined and backfilled as the count of published, public, moderation-`ok`, non-deleted works, then maintained for insert/delete and publication/visibility/moderation transitions.

## Reporting and evidence

User reports use stable reason codes and retain the existing manual-review status machine. The report row is inserted first; optional images are re-encoded client-side to remove metadata, then sent sequentially to an authenticated `report-evidence-upload` Edge Function. The function verifies report ownership, body size, decoded magic bytes, dimensions, absence of JPEG/PNG metadata containers, and the three-file limit before writing to the private bucket and registering `report_evidence`. A failed evidence upload does not discard an already-submitted report.

The evidence function generates the object path; client-supplied paths and filenames are never trusted or stored. The admin reports function resolves `target_type=user`, creates short-lived evidence URLs, and keeps report resolution auditable. Report counts never trigger automatic sanctions.

## Blocking semantics

“拉黑” is a first-party logged-in UI rule: both-direction content and people results are filtered, follow attempts are rejected, and existing follows are removed. The product copy explicitly does not promise anonymous or other-account URL removal. Unblock never recreates a follow.

## Dependency decision

Use the repository's previously resolved `file_picker` 8.3.7. Its iOS implementation uses PHPicker for images, so screenshots and photos can be selected without broad Photo Library permission. The version is exact-pinned and resolved offline before the device build; device builds still run with `--no-pub`.
