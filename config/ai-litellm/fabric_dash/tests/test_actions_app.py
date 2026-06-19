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
        await pilot.press("s")          # sync = RESTART, needs confirm
        await pilot.pause()
        assert calls == []              # nothing ran yet — modal is up
        await pilot.press("escape")     # cancel
        await pilot.pause()
        assert calls == []              # cancelled -> still nothing
        await pilot.press("s")
        await pilot.pause()
        await pilot.press("enter")      # confirm
        await pilot.pause()
        assert calls and calls[0][:2] == ["ai-litellm", "sync"]


@pytest.mark.asyncio
async def test_safe_action_runs_without_modal():
    calls = []
    from fabric_dash.app import FabricApp
    app = FabricApp(client=_client(), runner=ActionRunner(spawn=lambda a: (calls.append(a) or (0, ["ok"]))))
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("S")          # start = SAFE
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
        await pilot.press("enter")          # confirm billable
        await pilot.pause()
    assert app.return_value == ("launch", ["claude"])
