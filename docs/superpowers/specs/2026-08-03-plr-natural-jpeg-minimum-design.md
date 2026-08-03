# PLR natural-photo minimum experiment design

The accepted funnel is: stop the legacy cross-photo candidate; freeze and
audit official PLR; train or adapt one shared global natural-photo model only
when an official complete codec exists; test one frozen PocketWorld JPEG; count
the full stream and model cost; verify source length, SHA-256, and every byte;
then scale only after a strict same-input JXL win.

The frozen public PLR revision fails the first executable-codec gate. Detailed
requirements, evidence, and the non-result are recorded under
`openspec/changes/benchmark-plr-natural-jpeg-minimum/` and
`experiments/plr_official_natural_jpeg/`.

This finding does not show that PLR's entropy model compresses poorly. It shows
that the current public release cannot produce the exact-JPEG artifact required
for a valid PocketWorld A/B without new local implementation.
