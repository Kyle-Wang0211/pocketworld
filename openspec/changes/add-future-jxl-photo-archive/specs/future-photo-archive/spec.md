## ADDED Requirements
### Requirement: Future-only archive eligibility
The system SHALL archive a capture only when a compatible photo-archive policy
marker was written when that capture directory was created. A capture without
that marker MUST remain unmodified regardless of its files, timestamps, name,
or apparent completeness.

#### Scenario: Newly created marked capture
- **WHEN** a new official capture directory is created by an archive-capable build
- **THEN** the system writes a durable compatible policy marker before any photo can become an archive candidate

#### Scenario: Legacy complete capture
- **WHEN** a complete capture has JPEGs, a bundle manifest, PLY, and metadata but no compatible marker
- **THEN** automatic discovery and lifecycle notifications leave every file unchanged

#### Scenario: Malformed or unknown marker
- **WHEN** the policy marker is malformed or declares an unsupported schema, codec, mode, or revision
- **THEN** the system fails closed and does not encode or delete any JPEG

### Requirement: Cold-pipeline lifecycle gate
The system SHALL start archive work only after the authoritative photo bundle,
non-empty final PLY, sparse metadata, and reconstruction release are all
confirmed for an eligible capture. It MUST NOT archive while official capture
or reconstruction work is active.

#### Scenario: PLY has not been persisted
- **WHEN** a marked capture has source JPEGs but either final PLY or metadata is absent
- **THEN** the system retains all source JPEGs and leaves the capture pending

#### Scenario: Reconstruction still owns the capture
- **WHEN** final artifacts exist but the reconstruction resource for the capture has not been released
- **THEN** no candidate is encoded or deleted

#### Scenario: Foreground work becomes active
- **WHEN** capture or reconstruction activity begins during a multi-file archive
- **THEN** the system finishes at most the current single-file transaction and pauses before the next candidate

#### Scenario: Eligible interrupted work after restart
- **WHEN** the app restarts with no in-process reconstruction owner and discovers a marked capture satisfying the on-disk gates
- **THEN** the system resumes its idempotent archive reconciliation

### Requirement: Authoritative candidate selection
The system SHALL consider only safe high-resolution JPEG basenames referenced
by `frames[*].highresFilename` in `official_photo_bundle.json`. It MUST NOT
archive previews, thumbnails, unreferenced files, sidecars, databases, point
clouds, or paths outside `photos_highres`.

#### Scenario: Referenced and unreferenced JPEGs coexist
- **WHEN** the high-resolution directory contains a manifest-referenced JPEG and an orphan JPEG
- **THEN** only the referenced JPEG is considered for archival

#### Scenario: Unsafe manifest path
- **WHEN** a frame declares an absolute path, path separator, parent traversal, duplicate, or non-JPEG high-resolution filename
- **THEN** that entry is rejected without touching the declared target

### Requirement: Transient AR previews
For future marked captures, the system SHALL treat 1920×1440 AR-card preview
JPEGs as temporary capture UI data rather than durable project inputs. It SHALL
write any persistent draft thumbnail outside the capture preview directory,
omit previews from the future photo-bundle validation and transport contract,
and remove the capture preview directory only after the draft record is
durable. Cleanup MUST NOT target an unmarked capture.

#### Scenario: Draft persistence succeeds
- **WHEN** a future marked capture has copied its independent draft thumbnail and durably stored its draft record
- **THEN** the system deletes `<capture>/previews` without modifying `photos_highres` or the independent thumbnail

#### Scenario: Immediate cleanup is interrupted
- **WHEN** the app stops after draft persistence but before deleting previews
- **THEN** marker-gated cold archive reconciliation retries the preview cleanup

#### Scenario: Legacy unmarked capture contains previews
- **WHEN** startup discovery encounters an unmarked capture with a preview directory
- **THEN** the system leaves that directory and every contained file unchanged

#### Scenario: Future bundle validation and transport
- **WHEN** a future manifest omits `previewsDir` and per-frame `previewFilename`
- **THEN** validation does not report missing previews, asset repair does not regenerate them, and transport does not require a preview directory

### Requirement: Byte-exact JPEG XL transaction
For each candidate, the system SHALL use JPEG XL JPEG-reconstruction mode and
MUST prove that the reconstructed file is byte-for-byte identical to the
original JPEG before committing an archive or deleting the source. Decoded
pixel equality alone is insufficient.

#### Scenario: Exact smaller archive
- **WHEN** encoding succeeds, reconstruction matches every source byte, and the JXL file is smaller
- **THEN** the system atomically commits the JXL and verified manifest entry before deleting the source JPEG

#### Scenario: Reconstruction mismatch
- **WHEN** reconstructed bytes differ by any byte or length
- **THEN** the system deletes temporary output, retains the original JPEG, and does not publish a verified archive entry

#### Scenario: Codec failure
- **WHEN** the native encoder or reconstructor reports an error
- **THEN** the system retains the original JPEG and can retry safely later

#### Scenario: Archive is not smaller
- **WHEN** a byte-exact JXL is equal to or larger than its JPEG source
- **THEN** the system retains the JPEG and records or returns a non-destructive skipped result

### Requirement: Crash-safe durable state
The system SHALL make every file transaction idempotent and SHALL preserve at
least one complete recoverable representation across every ordered commit
boundary. The original JPEG MUST be the last durable representation removed.

#### Scenario: Crash before archive commit
- **WHEN** the process stops while only temporary JXL or verification files exist
- **THEN** restart removes or replaces the temporary files while retaining the canonical source JPEG

#### Scenario: Crash after manifest commit
- **WHEN** the process stops after a verified archive entry is durable but before source deletion
- **THEN** restart independently verifies the committed archive and then safely completes or declines source deletion

### Requirement: Verified exact-JPEG resolver
The system SHALL provide a resolver that returns an existing canonical JPEG or
materializes a byte-exact JPEG from a committed archive into cache. It MUST
verify the declared length and cryptographic digest before returning a
materialized path.

#### Scenario: Canonical source still exists
- **WHEN** a consumer requests a referenced JPEG whose source file remains
- **THEN** the resolver returns that file without transcoding

#### Scenario: Archive-only source is valid
- **WHEN** the source is absent and a committed archive reconstructs to the declared exact length and digest
- **THEN** the resolver atomically publishes and returns the cached JPEG

#### Scenario: Archive is missing or corrupt
- **WHEN** neither a canonical source nor a successfully verified archive is available
- **THEN** the resolver fails closed and never returns corrupt or unverified bytes

### Requirement: Cross-platform archive contract
The stored codec and metadata contract SHALL use open, platform-independent
JPEG XL semantics. Platform integrations MUST preserve the same exact-byte
verification rules and MUST NOT substitute an Apple-only image format.

#### Scenario: A new platform adds archive support
- **WHEN** another platform links a JPEG XL codec implementation
- **THEN** it can read the same policy and archive manifests and must pass the same exact-JPEG reconstruction contract
