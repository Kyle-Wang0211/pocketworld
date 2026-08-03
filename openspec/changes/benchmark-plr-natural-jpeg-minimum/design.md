# Design: Official PLR natural-photo minimum gate

## Context

The frozen source is `photos_highres/official_tap-2019.jpg` from capture
`cap_1785512421333592`: 2,725,495 bytes with SHA-256
`a1cb8de1d3b91edbb7e05233c7930200c46e04554c3651153e267e5abd262138`.
The saved same-input JXL effort-10 result is 2,215,345 bytes and restored the
source exactly on the physical iPhone.

The official PLR repository is frozen at commit
`8a65e4d0d3daa9292e40df0541e8f43fcaada2d7`, tree
`67796f3cfc8ef558d3b2287fcf315a8731ae1f14`. Public-source inspection is a
mandatory gate because training a rate model does not prove that a deployable
exact-JPEG codec exists.

## Decisions

### Audit before training

The official public route must provide all of the following without a local
algorithm repair: a checkpoint or reproducible training path, a callable
entropy encode/decode path, serialization of every returned entropy string and
shape, ingestion of original JPEG coefficients and metadata, and reconstruction
of the original JPEG file bytes. Missing any item stops the run as
`official_codec_incomplete`; it is not recorded as a compression loss.

### Do not substitute an estimated rate

Forward-pass likelihood or `bpp_loss` is diagnostic only. It must not be
compared with JXL's actual file size. Only a persisted archive measured with
`stat` and successfully decoded by the official path is eligible.

### Count the model honestly

If the public codec gate passes, report both:

- `standalone_effective_bytes = stream + container + exact_jpeg_side_data + model`
- `project_effective_bytes = stream + container + exact_jpeg_side_data + ceil(model / 141)`

The denominator 141 is fixed from the known source capture before seeing PLR
results. The saved 2,215,345-byte JXL file is the strict comparison threshold.
The standalone and 141-photo-amortized figures remain separate; neither may be
silently omitted.

### Preserve the minimum-unit funnel

There is one JPEG and one terminal run. No 100 MB corpus, cross-photo condition,
complete project, phone bundle, or production edit is allowed until exactness
passes and the registered effective metric is strictly smaller than JXL.

## Preflight finding

The frozen public revision fails the official-codec gate before training:

- the official training entry invokes only `model(...)`, logs `bpp_loss`, and
  saves PyTorch checkpoints; it never invokes `compress` or `decompress`;
- its selected `PNGFolder_Trans` path reads decoded pixels and creates synthetic
  DCT coefficients with `torchjpeg.codec.quantize_at_quality`, rather than
  preserving an arbitrary input JPEG's marker/header/metadata bytes;
- the selected model constructs `Gaussian_Y` and `Gaussian_CbCr`, while its
  public `compress/decompress` methods refer to multiple different, undefined
  attributes;
- no official checkpoint, release asset, `jpegio.write`, whole-JPEG serializer,
  or byte/SHA restoration check exists in the frozen repository.

Therefore installing PyTorch or training on natural images cannot produce the
required official PLR archive. Repairing the missing codec would be a new
PocketWorld implementation, not a faithful run of the official release.

## Status

`preflight_rejected_official_codec_incomplete`. Production and the saved JXL
baseline remain unchanged.
