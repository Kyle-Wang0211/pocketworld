from pw_plr.terminal_baseline_diagnostic import classify_secondary_baseline


def test_secondary_baseline_distinguishes_a_formal_only_win() -> None:
    assert (
        classify_secondary_baseline(
            candidate_bytes=4_900,
            formal_jxl_bytes=5_000,
            diagnostic_lepton_bytes=4_800,
        )
        == "winner_vs_jxl_only_loses_lepton"
    )


def test_secondary_baseline_reports_both_win_or_both_loss() -> None:
    assert (
        classify_secondary_baseline(
            candidate_bytes=4_700,
            formal_jxl_bytes=5_000,
            diagnostic_lepton_bytes=4_800,
        )
        == "winner_vs_jxl_and_lepton"
    )
    assert (
        classify_secondary_baseline(
            candidate_bytes=5_100,
            formal_jxl_bytes=5_000,
            diagnostic_lepton_bytes=4_800,
        )
        == "loser_vs_jxl_and_lepton"
    )
