# Proposal: benchmark an eight-photo global JPEG collection codec

The previous two-photo independent predictor lost to saved JXL because it fixed
one adjacent parent, copied quantized coefficient blocks, and flattened all
residuals. It therefore did not test the approved collection-level architecture.

Create one host-only, strict-lossless eight-photo experiment that selects a
global feature graph, performs hybrid global/local/intra DCT prediction, and
encodes typed frequency streams with the same pinned ZPAQ backend. Reference
saved JXL bytes without rerunning the baseline. Run the frozen candidate once
after synthetic TDD and stop before production or phone work.

