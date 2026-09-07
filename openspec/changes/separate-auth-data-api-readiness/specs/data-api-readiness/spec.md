# Data API readiness

## ADDED Requirements

### Requirement: Authentication and database readiness are distinct

The client SHALL treat a valid Supabase session and a usable PostgREST request
as separate states. A `PGRST303` future-issued-JWT response SHALL be retried a
bounded number of times with the exact same token and SHALL NOT invoke token
refresh. Token refresh and sign-out SHALL reset the data-API readiness state.
The complete logical feed transaction (works, blocks, profiles, and likes)
SHALL pin that token in its Authorization header. A nested blocks lookup SHALL
not swallow the transient `PGRST303` and falsely mark the data API ready.

#### Scenario: PostgREST has not yet accepted a newly issued token

- **WHEN** the first authenticated feed request returns `PGRST303` with a
  future-issued-JWT reason
- **THEN** the client waits for a bounded clock-skew interval and retries the
  same operation with the same token
- **AND** the community page remains in its loading state
- **AND** no raw backend exception is shown to the user

#### Scenario: The failure is not the transient clock-skew case

- **WHEN** a request fails for another reason or exhausts the bounded retry
- **THEN** the error remains a failed data-API state without changing auth
- **AND** the page offers a stable retry action with product-facing copy
