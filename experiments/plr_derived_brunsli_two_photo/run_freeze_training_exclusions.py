"""Persist the preregistered whole-capture training exclusion proof."""

from __future__ import annotations

import argparse
from pathlib import Path

from pw_plr.training_exclusion import freeze_training_exclusions


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    freeze_training_exclusions(arguments.config, arguments.output)


if __name__ == "__main__":
    main()
