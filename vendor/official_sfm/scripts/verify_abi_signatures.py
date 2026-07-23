#!/usr/bin/env python3
"""Prove the frozen pwsfm and pwofficial declarations have identical types."""

from pathlib import Path
import json
import os
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
SDK = subprocess.check_output(
    ["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True
).strip()
CLANG = subprocess.check_output(
    ["xcrun", "--sdk", "iphoneos", "--find", "clang"], text=True
).strip()


def ast(path: Path) -> dict:
    return json.loads(
        subprocess.check_output(
            [
                CLANG,
                "-target",
                "arm64-apple-ios14.0",
                "-isysroot",
                SDK,
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


with tempfile.TemporaryDirectory(prefix="pwofficial-abi-") as directory:
    consumer = Path(directory) / "official_header.c"
    consumer.write_text(f'#include "{ROOT / "include" / "official_sfm_c.h"}"\n')
    self_types: dict[str, str] = {}
    official_types: dict[str, str] = {}
    functions(ast(ROOT.parent / "aether_ffi" / "src" / "pwsfm_export_shim.c"),
              "pwsfm_", self_types)
    functions(ast(ROOT.parent / "aether_ffi" / "src" / "pw_telemetry.mm"),
              "pw_", self_types)
    functions(ast(consumer), "pwofficial_", official_types)

expected = {
    line.removeprefix("pwofficial_")
    for line in (ROOT / "pwofficial_abi_symbols.txt").read_text().splitlines()
    if line.strip()
}
if set(self_types) != expected:
    raise SystemExit(f"self ABI differs from frozen manifest: {set(self_types) ^ expected}")
if set(official_types) != expected:
    raise SystemExit(
        f"official header differs from frozen manifest: {set(official_types) ^ expected}"
    )

mismatches = {
    name: (self_types[name], official_types[name])
    for name in sorted(expected)
    if self_types[name] != official_types[name]
}
if mismatches:
    raise SystemExit(f"ABI signature mismatch: {mismatches}")

print(f"PASS: {len(expected)} pwsfm/pwofficial function signatures are identical")
