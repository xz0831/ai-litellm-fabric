import asyncio
import json
import threading
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
        # Cancel-first / Cancel-focused for a guarded (destructive) grade.
        assert app.focused is not None and app.focused.id == "confirm-no"
        # Verify the actual guarded layout (round-1 review #12 replaced a dead
        # `not has_class("destructive")` — a class nothing ever sets, so always
        # true): Cancel must come first in DOM order and Confirm is the warning.
        from textual.widgets import Button
        buttons = list(screen.query("#confirm-buttons Button"))
        assert [b.id for b in buttons] == ["confirm-no", "confirm-yes"]
        assert screen.query_one("#confirm-yes", Button).variant == "warning"
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


@pytest.mark.asyncio
async def test_action_does_not_freeze_event_loop():
    """Freeze-guard: the blocking spawn must NOT block the asyncio event loop.

    Design: use a background OS ticker thread (not asyncio) to record
    timestamps independently of the event loop.  The spawn blocks on a gate
    for ~300ms.  We compare ticker timestamps DURING the spawn window to the
    spawn window: if ANY async ticker timestamp appears between spawn_start
    and spawn_end, the event loop was free (fix).  The OS-thread ticker always
    runs regardless; the asyncio ticker only runs if the loop is free.

    Why RED on the buggy code: the async ticker coroutine (await asyncio.sleep)
    cannot fire while the event loop is frozen by the blocking spawn.  It
    records 0 ticks before spawn_end → FAIL.

    Why GREEN after the fix: the spawn runs in a thread pool; the event loop
    is free; the async ticker fires many times in the 300ms window → PASS.
    """
    import time as _time

    gate = threading.Event()              # release after the window
    spawn_start_time: list = []          # [float] set at spawn entry
    spawn_end_time: list = []            # [float] set at spawn exit
    async_ticks: list = []               # timestamps from an asyncio coroutine
    spawn_started = threading.Event()    # signals that blocking has begun

    def slow_spawn(argv):
        spawn_start_time.append(_time.time())
        spawn_started.set()
        gate.wait(timeout=5)             # blocks for ~300ms (until released)
        spawn_end_time.append(_time.time())
        return (0, ["done"])

    async def async_ticker():
        """Record timestamps at ~10ms intervals (only runs if loop is free)."""
        try:
            while True:
                async_ticks.append(_time.time())
                await asyncio.sleep(0.01)
        except asyncio.CancelledError:
            pass

    from fabric_dash.app import FabricApp
    app = FabricApp(client=_client(), runner=ActionRunner(spawn=slow_spawn))

    # Releaser: waits for spawn to start, sleeps 300ms, then releases.
    # Runs in an OS thread so it is immune to event-loop freezing.
    def releaser():
        spawn_started.wait(timeout=3)
        _time.sleep(0.30)
        gate.set()

    rel_thread = threading.Thread(target=releaser, daemon=True)
    rel_thread.start()

    async with app.run_test() as pilot:
        await pilot.pause()
        tick_task = asyncio.ensure_future(async_ticker())

        # Trigger 's' (start = SAFE, no modal).  pilot.press will block for
        # the full worker duration on the buggy code (spawn holds the loop),
        # or return quickly on the fixed code (spawn is in a thread).
        await pilot.press("s")

        # pilot.press waited for the worker; let the releaser thread finish
        # in case it hasn't yet (fixed path: pilot.press returns before 300ms).
        rel_thread.join(timeout=1)

        tick_task.cancel()
        try:
            await tick_task
        except asyncio.CancelledError:
            pass

    # Sanity: spawn must have run.
    assert spawn_start_time, "spawn never called — action was not triggered"
    assert spawn_end_time, "spawn never returned — something went wrong"

    # Count async ticks that fell INSIDE the spawn window [start, end].
    t0, t1 = spawn_start_time[0], spawn_end_time[0]
    ticks_during_spawn = [t for t in async_ticks if t0 <= t <= t1]

    # On the buggy code: the async ticker cannot run while the loop is frozen,
    # so ticks_during_spawn == 0 and this assertion fails.
    # On the fixed code: the ticker fires freely, so ticks_during_spawn >= several.
    assert len(ticks_during_spawn) >= 5, (
        f"event loop was frozen while spawn blocked ({t1-t0:.3f}s window): "
        f"only {len(ticks_during_spawn)} async ticks during spawn "
        f"(total async ticks: {len(async_ticks)}). "
        "Fix: offload the blocking spawn to a thread via asyncio.to_thread."
    )


def test_action_runner_passes_stdin_without_logging_it():
    from fabric_dash.actions import ActionRunner
    seen = {}
    def spawn(argv, stdin_input=None):
        seen["argv"] = argv
        seen["stdin"] = stdin_input
        return (0, ["Stored OPENROUTER_API_KEY in macOS Keychain"])
    logged = []
    rc = ActionRunner(spawn=spawn).run(["key", "set", "--keychain", "openrouter"],
                                       logged.append, stdin_input="sk-secret-123")
    assert rc == 0
    assert seen["argv"] == ["ai-litellm", "key", "set", "--keychain", "openrouter"]  # NO secret in argv
    assert seen["stdin"] == "sk-secret-123"                                          # secret only via stdin
    assert all("sk-secret-123" not in line for line in logged)                       # secret never logged


def test_action_runner_no_stdin_still_calls_one_arg_spawn():
    # Existing fakes are 1-arg lambdas; the no-stdin path must not pass a 2nd arg.
    from fabric_dash.actions import ActionRunner
    calls = []
    rc = ActionRunner(spawn=lambda argv: (calls.append(argv) or (0, [])) ).run(
        ["proxy", "start"], lambda _l: None)
    assert rc == 0 and calls == [["ai-litellm", "proxy", "start"]]
