# Change: Benchmark official backends on one complete descriptor chunk

## Why

Earlier full-size experiments mixed structural and backend effects and made
failed hypotheses expensive. A smallest-unit screen is needed before any more
large benchmark work.

## What changes

- Add a host-only benchmark for one complete 16,384 by 128 descriptor chunk.
- Compare pinned OpenZL ACE and B2ND BYTEDELTA with existing backend screens.
- Require complete size accounting, exact reconstruction, and corruption
  rejection.
- Do not change production or promote a winner.
