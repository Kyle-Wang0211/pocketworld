# OpenMVS RNG provenance notice

This directory preserves the licensing and immutable source identity for the
small uint32 seed and random-number expressions translated into
`openmvs_pcg_reference.h` and `openmvs_pcg.glsl`.

The expressions come from OpenMVS `libs/MVS/PatchMatchMetal.metal` at commit
`8efd9c48e7249b4256ca3a778cb6bf062b871771`. The upstream file states:

- Copyright (c) 2014-2026 SEACAVE.
- Author: cDc `<cdc.seacave@gmail.com>`.
- The Metal backend was contributed by leNeo.
- The source is offered under GNU Affero General Public License version 3 or,
  at the recipient's option, any later version.
- Legal notices and author attributions must be preserved.

PocketWorld's C++17 and GLSL files are cross-platform translations of only the
seed initialization and RNG expressions. They do not vendor or invoke the
upstream platform backend. See `provenance.json` for source and license hashes,
and `LICENSE` for the verbatim upstream AGPL version 3 license document.
