"""Verify the frozen input manifest and persist an atomic JSON result."""

from __future__ import annotations

import argparse
from dataclasses import asdict
import json
import os
from pathlib import Path

from pw_plr.input_identity import verify_inputs


def run(manifest_path: Path, output_path: Path) -> None:
    verified = verify_inputs(manifest_path)
    result = {
        "schema": "pw_plr_input_verification_v1",
        "status": "verified",
        "inputs": [
            {**asdict(item), "path": str(item.path)}
            for item in verified
        ],
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = output_path.with_suffix(output_path.suffix + ".tmp")
    temporary_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    os.replace(temporary_path, output_path)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    run(arguments.manifest, arguments.output)


if __name__ == "__main__":
    main()
