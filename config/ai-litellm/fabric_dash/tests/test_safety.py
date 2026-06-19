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
    assert by_key["s"].grade == safety.RESTART and by_key["s"].needs_confirm
    assert by_key["d"].grade == safety.SAFE and not by_key["d"].needs_confirm
    # no destructive action in the bar
    assert all(a.grade != safety.DESTRUCTIVE for a in safety.ACTIONS)
