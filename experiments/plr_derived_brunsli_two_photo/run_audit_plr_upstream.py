"""Persist a static audit of the pinned public PLR 4:2:0 entry point."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path

from pw_plr.plr_audit import audit_class_source


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    source_bytes = arguments.source.read_bytes()
    result = audit_class_source(
        source_bytes.decode(),
        "TransJPEGRecompression422",
    )
    document = {
        "schema": "pw_plr_upstream_static_audit_v1",
        "upstream_revision": arguments.revision,
        "source_path": str(arguments.source),
        "source_sha256": hashlib.sha256(source_bytes).hexdigest(),
        **result,
        "verdict": (
            "upstream_public_training_forward_and_codec_methods_require_completion"
            if result["compress_undefined_attributes"]
            or result["decompress_undefined_attributes"]
            or not result["forward_reads_gaussian_cbcr"]
            else "no_static_gap_detected"
        ),
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = arguments.output.with_suffix(arguments.output.suffix + ".tmp")
    temporary.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, arguments.output)


if __name__ == "__main__":
    main()
