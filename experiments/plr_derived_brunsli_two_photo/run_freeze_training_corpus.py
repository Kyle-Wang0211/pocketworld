"""Persist the preregistered first-party Phase 2 training corpus."""

from __future__ import annotations

import argparse
from pathlib import Path

from pw_plr.training_corpus import freeze_training_corpus


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    freeze_training_corpus(arguments.config, arguments.output)


if __name__ == "__main__":
    main()
