from fabric_dash import safety

def test_classify_restart_and_billable_and_safe():
    assert safety.classify(["proxy", "sync"]) == safety.RESTART
    assert safety.classify(["sync"]) == safety.RESTART
    assert safety.classify(["proxy", "restart"]) == safety.RESTART
    assert safety.classify(["proxy", "stop"]) == safety.RESTART
    assert safety.classify(["route", "probe", "x"]) == safety.BILLABLE
    assert safety.classify(["reasoning", "probe", "x"]) == safety.BILLABLE
    assert safety.classify(["uninstall"]) == safety.DESTRUCTIVE
    assert safety.classify(["proxy", "start"]) == safety.SAFE
    assert safety.classify(["proxy", "status"]) == safety.SAFE

def test_action_registry_marks_confirm():
    by_key = {a.key: a for a in safety.ACTIONS}
    # Convention: UPPERCASE = mutating (needs confirm), lowercase = safe.
    assert by_key["S"].grade == safety.RESTART and by_key["S"].needs_confirm  # sync
    assert by_key["s"].grade == safety.SAFE and not by_key["s"].needs_confirm  # start
    assert by_key["d"].grade == safety.SAFE and not by_key["d"].needs_confirm  # doctor
    # no destructive action in the bar
    assert all(a.grade != safety.DESTRUCTIVE for a in safety.ACTIONS)


def test_classify_matches_actions_grade():
    """Drift guard: classify(argv) must agree with the hand-set grade in ACTIONS.

    The runtime confirm gate keys off Action.needs_confirm, not classify(), so
    the two can silently diverge. This test couples them so any mismatch is
    caught at test time."""
    for a in safety.ACTIONS:
        assert safety.classify(list(a.argv)) == a.grade, (
            f"{a.key!r} ({a.label!r}) grade drift: "
            f"classify({list(a.argv)!r}) != {a.grade!r}"
        )


def test_keybinding_case_maps_to_risk():
    """lowercase keys must be safe; UPPERCASE keys must be the mutating ones.

    Guards against the case-collision finding: a mistyped Shift should always
    move toward the guarded (confirm-gated) side, never silently fire a
    disruptive action."""
    for a in safety.ACTIONS:
        assert len(a.key) == 1
        if a.key.islower():
            assert a.grade == safety.SAFE and not a.needs_confirm, a
        else:
            assert a.grade != safety.SAFE and a.needs_confirm, a
