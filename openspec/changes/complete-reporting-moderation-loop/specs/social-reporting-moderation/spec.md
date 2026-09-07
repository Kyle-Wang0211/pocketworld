# Social Reporting and Moderation Specification

## ADDED Requirements

### Requirement: Two report tiers

The product SHALL expose a standard report tier with a 50-character detail limit and a rights complaint tier with a 500-character detail limit.

#### Scenario: Standard report detail

- **WHEN** a user selects a standard reason
- **THEN** the UI and server SHALL reject detail longer than 50 characters

#### Scenario: Rights complaint detail

- **WHEN** a user selects impersonation or privacy/IP
- **THEN** the UI and server SHALL accept up to 500 characters and up to three typed evidence images

### Requirement: Server-owned report identity

The server SHALL derive the reporter from the authenticated token, validate the target account and optional source work, and reject reports against the reporter's own account or work.

#### Scenario: Forged work relationship

- **WHEN** a submitted source work does not belong to the target account
- **THEN** the server SHALL reject the request without creating a report

### Requirement: Sensitive evidence preservation

For minor-safety and sexual-content reports, the client SHALL NOT upload user-supplied evidence and the server SHALL preserve the linked first-party work assets for moderation.

#### Scenario: Sensitive report with linked work

- **WHEN** a sensitive report references a valid work
- **THEN** the durable report SHALL survive partial preservation failure and record the preservation state

### Requirement: Deterministic moderation priority

The server SHALL assign priority and due time from the reason, and the review queue SHALL sort by priority descending, due time ascending and creation time ascending.

#### Scenario: Minor safety outranks routine spam

- **WHEN** a minor-safety and spam report are both pending
- **THEN** the minor-safety report SHALL be listed first regardless of later creation time

### Requirement: Reporter-safe status history

The reporter SHALL be able to read their own report status and public feedback, but SHALL NOT receive internal moderator notes, reviewer identity, private evidence paths or service credentials.

#### Scenario: Resolved report

- **WHEN** a moderator resolves a report
- **THEN** the reporter SHALL see the public outcome while internal notes remain unavailable

### Requirement: Least-privilege moderation

Reviewers SHALL authenticate with individual user accounts and role checks. Reviewer clients SHALL NOT receive the Supabase service-role secret.

#### Scenario: Non-moderator access

- **WHEN** an authenticated non-moderator calls the moderation queue
- **THEN** the server SHALL return forbidden without revealing queue data

### Requirement: Provider portability

Flutter UI SHALL depend on a reporting repository rather than direct table access, and third-party moderation SHALL be represented by a server-side provider boundary.

#### Scenario: No configured provider

- **WHEN** no external moderation provider is configured
- **THEN** reports SHALL continue through the human moderation queue without simulated provider results
