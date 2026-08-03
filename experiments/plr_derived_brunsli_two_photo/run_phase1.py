"""Run the frozen Phase 1 exact-container experiment once and persist JSON."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from pw_plr.brunsli_phase1 import run_phase1 as execute_phase1


def run(
    *,
    manifest_path: Path,
    revision: str,
    adapter_path: Path,
    work_directory: Path,
    output_path: Path,
) -> None:
    result = execute_phase1(
        manifest_path=manifest_path,
        adapter_path=adapter_path,
        revision=revision,
        work_directory=work_directory,
    )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = output_path.with_suffix(output_path.suffix + ".tmp")
    temporary_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    os.replace(temporary_path, output_path)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--revision", choices=("v0.1", "master"), required=True)
    parser.add_argument("--adapter", type=Path, required=True)
    parser.add_argument("--work-directory", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    run(
        manifest_path=arguments.manifest,
        revision=arguments.revision,
        adapter_path=arguments.adapter,
        work_directory=arguments.work_directory,
        output_path=arguments.output,
    )


if __name__ == "__main__":
    main()
