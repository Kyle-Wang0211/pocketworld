#!/usr/bin/env python3
"""Generate the independent public ABI from the frozen production type header."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "include" / "aether_sfm_c.h"
OUTPUT = ROOT / "include" / "official_sfm_c.h"
SYMBOLS = [
    line.strip()
    for line in (ROOT / "pwofficial_abi_symbols.txt").read_text().splitlines()
    if line.strip()
]

source = SOURCE.read_text()
declaration_pattern = re.compile(
    r"^(?:void|int|const\s+char\s*\*|aether_sfm_result_t)\s+"
    r"aether_sfm_[A-Za-z0-9_]+\s*\([^;]*;\n?",
    re.MULTILINE | re.DOTALL,
)
type_surface = declaration_pattern.sub("", source)
type_surface = type_surface[: type_surface.rfind("#ifdef __cplusplus")]
type_surface = type_surface.replace(
    "AETHER_SFM_C_H", "POCKETWORLD_OFFICIAL_SFM_C_H"
)
type_surface = type_surface.replace(
    "aether_sfm — on-device Structure-from-Motion C ABI.",
    "pwofficial — physically independent copy of the production SfM C ABI.",
)
type_surface = type_surface.replace("AETHER_", "OFFICIAL_AETHER_")
type_surface = type_surface.replace("OFFICIAL_AETHER_SFM_", "AETHER_SFM_")
type_surface = type_surface.replace("pwsfm_gpu_match", "pwofficial_gpu_match")

declarations = []
for official in SYMBOLS:
    suffix = official.removeprefix("pwofficial_")
    if suffix == "telemetry":
        declarations.append(
            "int pwofficial_telemetry(double* phys_footprint_mb,\n"
            "                         double* footprint_peak_mb,\n"
            "                         int* thermal_state);"
        )
        continue
    source_name = f"aether_sfm_{suffix}"
    # Function declarations were removed above, so this updates only comment
    # cross-references while preserving the backend's aether_sfm_* type names.
    type_surface = type_surface.replace(source_name, official)
    pattern = re.compile(
        rf"^(?:void|int|aether_sfm_result_t)\s+{re.escape(source_name)}\s*\([^;]*;",
        re.MULTILINE | re.DOTALL,
    )
    match = pattern.search(source)
    if match is None:
        raise SystemExit(f"missing source declaration for {official}: {source_name}")
    declarations.append(match.group(0).replace(source_name, official, 1))

output = (
    type_surface
    + "// Frozen one-to-one copy of the public pwsfm_* export surface.\n"
    + "\n\n".join(declarations)
    + "\n\n#ifdef __cplusplus\n}  // extern \"C\"\n#endif\n\n"
    + "#endif  // POCKETWORLD_OFFICIAL_SFM_C_H\n"
)
OUTPUT.write_text(output)
