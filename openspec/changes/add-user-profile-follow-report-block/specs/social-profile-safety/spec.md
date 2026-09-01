# Social profile and safety delta

## ADDED Requirements

### Requirement: Author identity navigates to a usable profile

The product SHALL open a user profile when a community work-card author name or handle is tapped.

#### Scenario: A viewer taps an author

- **WHEN** a community card author is tapped
- **THEN** the app pushes that author's profile
- **AND** the feed is not replaced by an author-filter state

#### Scenario: A profile renders its chrome

- **WHEN** another user's profile loads
- **THEN** the back affordance contains no username
- **AND** a small overflow affordance is in the top-right
- **AND** its menu is anchored below that affordance rather than presented as a bottom sheet
- **AND** no “公开作品” heading or tab is rendered above the grid

### Requirement: Follow relationships are usable and block-aware

Authenticated users SHALL be able to follow and unfollow another visible user, view their own following list, and navigate from that list to profiles. A block in either direction SHALL reject a new follow and SHALL remove existing follows in both directions.

#### Scenario: A viewer follows another user

- **WHEN** the viewer taps “关注” and neither party has blocked the other
- **THEN** exactly one follow row exists
- **AND** both cached counts update
- **AND** the button becomes “已关注”

#### Scenario: A block exists in either direction

- **WHEN** either party attempts to follow the other
- **THEN** the write is rejected
- **AND** no count changes

#### Scenario: The viewer opens My Following

- **WHEN** the viewer taps their following count on Me
- **THEN** the list contains the accounts they follow
- **AND** each row supports profile navigation and unfollow

### Requirement: Work count means public visible works

`profiles.works_count` SHALL equal the number of that profile's works whose `published_at` is non-null, visibility is public, moderation status is `ok`, and `deleted_at` is null.

#### Scenario: A work changes visibility or moderation state

- **WHEN** a work enters or leaves the published, public, moderation-`ok`, non-deleted set
- **THEN** the profile work count changes by exactly one

### Requirement: User reports carry structured context and private evidence

The app SHALL offer the approved nine reason categories, at most 500 characters of context, and at most three conditionally allowed JPG/PNG attachments. Evidence SHALL be private and tied to a report owned by the uploader.

#### Scenario: A normal report includes images

- **WHEN** a user submits a report with up to three images
- **THEN** the report row enters the manual-review queue
- **AND** each decoded image is re-encoded without EXIF/GPS
- **AND** each stored image is at most 5 MiB and 2048 pixels on its longest edge
- **AND** an administrator receives only short-lived evidence URLs

#### Scenario: A sensitive minor or intimate-content reason is selected

- **WHEN** the reason is designated sensitive
- **THEN** the evidence picker is not shown
- **AND** the UI explains that linked in-product content will be preserved by the platform

#### Scenario: An image upload fails after the report row is accepted

- **WHEN** one or more evidence uploads fail
- **THEN** the report remains submitted
- **AND** the user is told that some images were not uploaded

### Requirement: User reports receive manual, auditable review

Account-level punishment SHALL NOT be automatically caused by report counts. Administrators SHALL be able to inspect the reported account, reason, context, source work, and private evidence, then enter review, dismiss, or mark the report actioned with notes and an audit record.

#### Scenario: An administrator opens a user report

- **WHEN** the moderation queue lists a pending user report
- **THEN** the target resolves to the reported profile
- **AND** evidence is visible only through expiring signed URLs
- **AND** every resolution records operator, timestamp, outcome, and notes

### Requirement: Blocking copy matches enforceable scope

The logged-in first-party PocketWorld UI SHALL hide both parties from each other's community/search/follow/profile flows after a block and SHALL prevent new follows. The UI SHALL NOT claim that public links, anonymous users, or other accounts lose access.

#### Scenario: A viewer confirms a block

- **WHEN** the block succeeds
- **THEN** both follow directions are removed
- **AND** the blocked user disappears from first-party social views
- **AND** the target is not notified

#### Scenario: A viewer unblocks an account

- **WHEN** the viewer removes a block from settings
- **THEN** visibility and future follow eligibility return
- **AND** no follow relationship is recreated automatically
