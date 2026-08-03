# PLR natural-photo minimum execution plan

1. Freeze upstream, input, baseline, worktree identity, cost formula, and stop
   rules.
2. Audit the official train/encode/decode/JPEG reconstruction path before
   installing dependencies.
3. If complete, train once on natural photos and serialize a fixed model.
4. Encode and officially decode one frozen PocketWorld JPEG.
5. Compare complete cost with saved same-input JXL only after byte and SHA-256
   equality.
6. Expand to cross-photo conditioning and a complete work only after a strict
   minimum-unit win.

Execution stopped at step 2 because the frozen public source has no executable
whole-JPEG codec. Steps 3-6 remain deliberately unrun rather than being filled
with a local, non-official substitute.
