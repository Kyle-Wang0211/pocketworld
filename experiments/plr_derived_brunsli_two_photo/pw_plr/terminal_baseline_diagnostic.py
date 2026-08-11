"""Classify the non-decision Lepton comparison beside the formal JXL gate."""

from __future__ import annotations


def classify_secondary_baseline(
    *,
    candidate_bytes: int,
    formal_jxl_bytes: int,
    diagnostic_lepton_bytes: int,
) -> str:
    if min(candidate_bytes, formal_jxl_bytes, diagnostic_lepton_bytes) <= 0:
        raise ValueError("terminal baseline bytes must be positive")
    wins_jxl = candidate_bytes < formal_jxl_bytes
    wins_lepton = candidate_bytes < diagnostic_lepton_bytes
    if wins_jxl and wins_lepton:
        return "winner_vs_jxl_and_lepton"
    if wins_jxl:
        return "winner_vs_jxl_only_loses_lepton"
    if wins_lepton:
        return "winner_vs_lepton_only_loses_jxl"
    return "loser_vs_jxl_and_lepton"
