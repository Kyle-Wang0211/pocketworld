# Change: Add usable user profiles, follows, reporting, and blocking

## Why

Community work cards currently treat the author name as an in-feed filter. The database already contains follows, blocks, report rows, and profile counters, but the product has no real author profile, follow control, or “My Following” list. User-report handling also lacks account-target UI, evidence attachments, and a complete administrator view.

## What changes

- Route author taps to a real public user profile.
- Add follow/unfollow and a following list reachable from Me.
- Make profile work count mean public, non-removed works.
- Replace the profile overflow bottom sheet with a small top-right anchored menu.
- Add the approved nine-category user-report flow, 500-character context, conditional image evidence, and a private evidence bucket.
- Resolve user targets and evidence in the moderation queue.
- Harden follows against blocks in both directions and expose unblock management.

## Non-goals

- Private-account follow requests, direct messaging, recommendations, or automatic account punishment.
- A claim that blocking removes public URLs from anonymous users or other accounts.

## Acceptance

- Card author taps open the author's profile.
- Follow state and counts remain consistent after follow, unfollow, block, and unblock.
- “My Following” is reachable from Me and supports navigation and unfollow.
- Profile chrome and report flow match the approved fifth prototype.
- Report evidence is private and visible to the manual-review console through short-lived URLs.
- Automated Flutter/Deno checks and the iOS Release build pass before the production-device update runbook begins.

