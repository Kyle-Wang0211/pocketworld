# Change: Add SQLite dual-candidate production archive

## Why

The verified `track_delta_v1` descriptor transform reduces a complete real
SQLite ZPAQ archive by 2.455% versus raw ZPAQ. Production needs to capture that
local gain without making any database layout an unsafe assumption and without
weakening the existing source-last deletion transaction.

## What Changes

- Generate raw-ZPAQ and track-delta-plus-ZPAQ candidates for future eligible
  official SQLite databases.
- Independently restore and byte-verify every candidate before comparing size.
- Publish only the smallest verified candidate and record its version in a v2
  manifest while retaining v1 raw-ZPAQ read compatibility.
- Restore track-delta archives through a versioned inverse transform before
  exposing the exact original database.
- Cooperatively stop preprocessing and compression when production work starts.
- Validate through a physically independent iPhone benchmark bundle before
  production admission.

## Impact

- Dart archive transaction, manifest, resolver, coordinator, and runtime wiring.
- A small C++17 SQLite transform FFI bridge compiled into the iOS application.
- No migration of existing archives and no change to the production app data
  container during benchmark validation.
