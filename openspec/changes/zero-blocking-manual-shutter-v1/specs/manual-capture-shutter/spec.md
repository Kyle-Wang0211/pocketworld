# Manual capture shutter requirements

## ADDED Requirements

### Requirement: immediate loss-aware admission

The production manual shutter SHALL synchronously admit each valid tap into a
bounded FIFO without waiting for camera, JPEG, disk, telemetry, or SfM work.

#### Scenario: rapid taps

- **WHEN** a user taps repeatedly below the 300-photo cap
- **THEN** every tap receives one ordered ticket
- **AND** the white shutter remains enabled while tickets are outstanding

### Requirement: canonical originals remain authoritative

Each successful ticket SHALL use the existing native 4032x3024 transaction and
same-frame camera metadata. Preview imagery SHALL NOT substitute for the
canonical reconstruction/texture original.

#### Scenario: queued transaction completes

- **WHEN** a queued ticket completes native capture
- **THEN** its canonical JPEG exists before album acknowledgement
- **AND** the validated JPEG path and capture metadata enter the existing SfM
  feed unchanged

### Requirement: lifecycle is finite and ownership-safe

The system SHALL not retry a permanently failed camera forever, issue repeated
captures against a background-stopped ARSession, or delete a capture directory
while an active native ticket owns a file.

#### Scenario: background and resume

- **WHEN** ARKit is stopped because the app is hidden
- **THEN** the active ticket waits without retry churn
- **AND** resumes in FIFO order only after ARKit successfully restarts

#### Scenario: discard

- **WHEN** the user confirms discard
- **THEN** pending work is cancelled and active retry is stopped
- **AND** recursive deletion occurs only after the active owner settles
