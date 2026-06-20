import json
import pytest
from fabric_dash.actions import ActionRunner


def test_runner_streams_and_returns_rc():
    def spawn(argv):
        assert argv[0] == "ai-litellm"
        return (0, ["line1", "line2"])
    seen = []
    rc = ActionRunner(spawn=spawn).run(["proxy", "start"], on_line=seen.append)
    assert rc == 0
    assert seen == ["line1", "line2"]


def _client():
    from fabric_dash.client import FabricClient
    def run(argv):
        if argv[:3] == ["ai-litellm", "proxy", "status"]:
            return (0, json.dumps({"health": "ok", "configCurrency": "current"}))
        return (0, "[]")
    return FabricClient(runner=run)


@pytest.mark.asyncio
async def test_restart_action_blocked_until_confirm():
    calls = []
    def spawn(argv):
        calls.append(argv)
        return (0, ["done"])
    from fabric_dash.app import FabricApp
    app = FabricApp(client=_client(), runner=ActionRunner(spawn=spawn))
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("S")          # sync = RESTART, needs confirm
        await pilot.pause()
        assert calls == []              # nothing ran yet — modal is up
        await pilot.press("escape")     # cancel
        await pilot.pause()
        assert calls == []              # cancelled -> still nothing
        await pilot.press("S")
        await pilot.pause()
        # Guarded (restart) modal defaults focus to Cancel — a reflexive Enter
        # must NOT fire the disruptive action.
        await pilot.press("enter")
        await pilot.pause()
        assert calls == []              # Enter on default Cancel -> still nothing
        await pilot.press("S")
        await pilot.pause()
        # Deliberate confirm: Tab to the Confirm button, then activate it.
        await pilot.press("tab")
        await pilot.press("enter")
        await pilot.pause()
        assert calls and calls[0][:2] == ["ai-litellm", "sync"]


@pytest.mark.asyncio
async def test_restart_modal_defaults_focus_to_cancel():
    from fabric_dash.app import FabricApp
    from fabric_dash.modal import ConfirmModal
    app = FabricApp(client=_client(), runner=ActionRunner(spawn=lambda a: (0, [])))
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("S")          # restart-grade (sync) modal
        await pilot.pause()
        screen = app.screen
        assert isinstance(screen, ConfirmModal)
        assert app.focused is not None and app.focused.id == "confirm-no"
        await pilot.press("escape")


@pytest.mark.asyncio
async def test_destructive_modal_renders_and_is_cancel_first():
    # No destructive action is wired into ACTIONS, but the modal must still
    # render a destructive-grade gate Cancel-first if one is ever pushed.
    from fabric_dash.app import FabricApp
    from fabric_dash.modal import ConfirmModal
    results = []
    app = FabricApp(client=_client(), runner=ActionRunner(spawn=lambda a: (0, [])))
    async with app.run_test() as pilot:
        await pilot.pause()
        app.push_screen(
            ConfirmModal("permanent: removes installed harness.", title="Confirm uninstall", grade="destructive"),
            results.append,
        )
        await pilot.pause()
        screen = app.screen
        assert isinstance(screen, ConfirmModal)
        # Cancel-first / Cancel-focused, and no dead .destructive class on the box.
        assert app.focused is not None and app.focused.id == "confirm-no"
        box = screen.query_one("#confirm-box")
        assert not box.has_class("destructive")
        await pilot.press("enter")          # Enter on default Cancel -> dismiss(False)
        await pilot.pause()
    assert results == [False]


@pytest.mark.asyncio
async def test_safe_action_runs_without_modal():
    calls = []
    from fabric_dash.app import FabricApp
    app = FabricApp(client=_client(), runner=ActionRunner(spawn=lambda a: (calls.append(a) or (0, ["ok"]))))
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("s")          # start = SAFE
        await pilot.pause()
        assert calls and calls[0][:2] == ["ai-litellm", "proxy"]


@pytest.mark.asyncio
async def test_launch_exits_with_handoff():
    from fabric_dash.app import FabricApp
    app = FabricApp(client=_client())
    async with app.run_test() as pilot:
        await pilot.pause()
        app._selected_harness = "claude"   # simulate selection
        await pilot.press("l")
        await pilot.pause()
        # Billable modal is now Cancel-first (guarded). Deliberate confirm:
        # Tab to move focus from Cancel -> Confirm, then activate it.
        await pilot.press("tab")
        await pilot.press("enter")
        await pilot.pause()
    assert app.return_value == ("launch", ["claude"])
