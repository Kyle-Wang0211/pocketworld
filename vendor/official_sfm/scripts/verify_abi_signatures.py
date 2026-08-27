#!/usr/bin/env python3
"""Prove shared pwsfm/pwofficial declarations have identical frozen types."""

from __future__ import annotations

from pathlib import Path
import json
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent


def ast(path: Path, *, clang: str, sdk: str) -> dict:
    return json.loads(
        subprocess.check_output(
            [
                clang,
                "-target",
                "arm64-apple-ios14.0",
                "-isysroot",
                sdk,
                "-fsyntax-only",
                "-Xclang",
                "-ast-dump=json",
                str(path),
            ],
            text=True,
        )
    )


def functions(node: object, prefix: str, out: dict[str, str]) -> None:
    if isinstance(node, dict):
        if node.get("kind") == "FunctionDecl":
            name = node.get("name", "")
            if name.startswith(prefix):
                out[name.removeprefix(prefix)] = node["type"]["qualType"]
        for child in node.get("inner", []):
            functions(child, prefix, out)
    elif isinstance(node, list):
        for child in node:
            functions(child, prefix, out)


def manifest_suffixes(
    path: Path,
    *,
    prefix: str,
    aliases: dict[str, str] | None = None,
) -> set[str]:
    aliases = aliases or {}
    suffixes: set[str] = set()
    for raw_line in path.read_text().splitlines():
        symbol = raw_line.strip()
        if not symbol:
            continue
        if symbol in aliases:
            suffix = aliases[symbol]
        elif symbol.startswith(prefix):
            suffix = symbol.removeprefix(prefix)
        else:
            raise ValueError(f"unexpected symbol in {path.name}: {symbol}")
        if not suffix or suffix in suffixes:
            raise ValueError(f"duplicate/empty ABI suffix in {path.name}: {suffix!r}")
        suffixes.add(suffix)
    return suffixes


def validate_surfaces(
    *,
    self_types: dict[str, str],
    official_types: dict[str, str],
    self_expected: set[str],
    official_expected: set[str],
    official_only_expected: set[str],
) -> tuple[set[str], set[str]]:
    if set(self_types) != self_expected:
        delta = sorted(set(self_types) ^ self_expected)
        raise ValueError(f"self ABI differs from frozen self manifest: {delta}")
    if set(official_types) != official_expected:
        delta = sorted(set(official_types) ^ official_expected)
        raise ValueError(f"official header differs from frozen official manifest: {delta}")

    missing_parity = self_expected - official_expected
    if missing_parity:
        raise ValueError(
            f"official ABI is missing frozen self-parity symbols: "
            f"{sorted(missing_parity)}"
        )

    shared = set(self_expected)
    actual_official_only = official_expected - shared
    if actual_official_only != official_only_expected:
        delta = sorted(actual_official_only ^ official_only_expected)
        raise ValueError(
            f"official ABI differs from frozen official-only manifest: {delta}"
        )
    mismatches = {
        name: (self_types[name], official_types[name])
        for name in sorted(shared)
        if self_types[name] != official_types[name]
    }
    if mismatches:
        raise ValueError(f"ABI signature mismatch: {mismatches}")
    return shared, actual_official_only


def main() -> None:
    sdk = subprocess.check_output(
        ["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True
    ).strip()
    clang = subprocess.check_output(
        ["xcrun", "--sdk", "iphoneos", "--find", "clang"], text=True
    ).strip()

    with tempfile.TemporaryDirectory(prefix="pwofficial-abi-") as directory:
        consumer = Path(directory) / "official_header.c"
        consumer.write_text(
            f'#include "{ROOT / "include" / "official_sfm_c.h"}"\n'
        )
        self_types: dict[str, str] = {}
        official_types: dict[str, str] = {}
        functions(
            ast(
                ROOT.parent / "aether_ffi" / "src" / "pwsfm_export_shim.c",
                clang=clang,
                sdk=sdk,
            ),
            "pwsfm_",
            self_types,
        )
        functions(
            ast(
                ROOT.parent / "aether_ffi" / "src" / "pw_telemetry.mm",
                clang=clang,
                sdk=sdk,
            ),
            "pw_",
            self_types,
        )
        functions(
            ast(consumer, clang=clang, sdk=sdk),
            "pwofficial_",
            official_types,
        )

    self_expected = manifest_suffixes(
        ROOT / "pwsfm_abi_symbols.txt",
        prefix="pwsfm_",
        aliases={"pw_telemetry": "telemetry"},
    )
    official_expected = manifest_suffixes(
        ROOT / "pwofficial_abi_symbols.txt",
        prefix="pwofficial_",
    )
    official_only_expected = manifest_suffixes(
        ROOT / "pwofficial_only_abi_symbols.txt",
        prefix="pwofficial_",
    )
    try:
        shared, official_only = validate_surfaces(
            self_types=self_types,
            official_types=official_types,
            self_expected=self_expected,
            official_expected=official_expected,
            official_only_expected=official_only_expected,
        )
    except ValueError as error:
        raise SystemExit(str(error)) from error

    print(
        f"PASS: {len(shared)} shared pwsfm/pwofficial signatures; "
        f"{len(official_only)} frozen official-only exports"
    )


if __name__ == "__main__":
    main()
