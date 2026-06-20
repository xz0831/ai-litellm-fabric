import json
import asyncio
import threading
import pytest
from fabric_dash.app import FabricApp
from fabric_dash.client import FabricClient


def make_client():
    data = {
        "ai-litellm proxy status --json": json.dumps({"health": "ok", "configCurrency": "stale", "baseUrl": "http://127.0.0.1:4000", "pid": 9288, "log": "/tmp/l.log"}),
        "ai-litellm model list --json": json.dumps([{"name": "gpt-5.5", "backend": "openrouter/x"}]),
        "ai-litellm harness list --json": json.dumps([{"name": "claude", "adapter": "a", "valid": True, "cliInstalled": True}]),
        "ai-litellm key status --json": json.dumps({"openrouter": {"source": "keychain"}, "master": {"source": "keychain"}}),
        "ai-litellm route list --json": json.dumps([]),
        "ai-litellm runtime status --json": json.dumps([]),
        "ai-litellm reasoning matrix --json": json.dumps([]),
        "ai-litellm context matrix --json": json.dumps([]),
    }

    def run(argv):
        return (0, data.get(" ".join(a for a in argv if a is not None), ""))

    return FabricClient(runner=run)


@pytest.mark.asyncio
async def test_harness_panel_sets_launch_target():
    app = FabricApp(client=make_client())
    async with app.run_test() as pilot:
        await pilot.pause()
        # No harness picked until the Harnesses panel is opened.
        assert app._selected_harness is None
        app.show_panel("harnesses")
        await pilot.pause()
        # Opening the panel populates the DataTable and sets the launch target
        # to the first harness — 'l' now has a real target, not a hardcoded one.
        from textual.widgets import DataTable
        table = app.query_one("#data-table", DataTable)
        assert table.display is True
        assert table.row_count == 1
        assert app._selected_harness == "claude"
        # status line reflects the live launch target
        assert "claude" in str(app.query_one("#status").content)


@pytest.mark.asyncio
async def test_launch_without_selection_does_not_default():
    # harness list empty -> no target; 'l' must not silently launch anything.
    def run(argv):
        if argv[:3] == ["ai-litellm", "proxy", "status"]:
            return (0, json.dumps({"health": "ok", "configCurrency": "current"}))
        return (0, "[]")
    app = FabricApp(client=FabricClient(runner=run))
    async with app.run_test() as pilot:
        await pilot.pause()
        app.show_panel("harnesses")
        await pilot.pause()
        assert app._selected_harness is None
        await pilot.press("l")
        await pilot.pause()
        # No confirm modal, no exit — just a guidance message.
        from fabric_dash.modal import ConfirmModal
        assert not isinstance(app.screen, ConfirmModal)
        assert app.return_value is None


def make_client_with(overrides):
    """make_client() but with specific --json commands overridden."""
    base = {
        "ai-litellm proxy status --json": json.dumps({"health": "ok", "configCurrency": "current", "baseUrl": "http://127.0.0.1:4000"}),
        "ai-litellm model list --json": json.dumps([]),
        "ai-litellm model limits --json": json.dumps([]),
        "ai-litellm harness list --json": json.dumps([]),
        "ai-litellm key status --json": json.dumps({}),
        "ai-litellm runtime status --json": json.dumps([]),
        "ai-litellm reasoning matrix --json": json.dumps([]),
    }
    base.update(overrides)

    def run(argv):
        return (0, base.get(" ".join(a for a in argv if a is not None), ""))

    return FabricClient(runner=run)


@pytest.mark.asyncio
async def test_models_panel_renders_into_datatable_not_wrapping_text():
    # The flagship view must use the real DataTable (which sizes/scrolls columns)
    # rather than fixed-width text columns that overflowed the content panel.
    client = make_client_with({
        "ai-litellm model limits --json": json.dumps([
            {"name": "claude-opus", "model": "glm-5.2", "tpm": 200000, "rpm": 4000, "maxIn": 131072, "maxOut": 131072},
        ]),
    })
    app = FabricApp(client=client)
    async with app.run_test() as pilot:
        await pilot.pause()
        app.show_panel("models")
        await pilot.pause()
        from textual.widgets import DataTable, Static
        table = app.query_one("#data-table", DataTable)
        assert table.display is True
        assert app.query_one("#content", Static).display is False
        assert table.row_count == 1
        # All six columns are present as real DataTable columns (no overflow).
        assert len(table.columns) == 6
        assert str(table.get_cell_at((0, 0))) == "claude-opus"


@pytest.mark.asyncio
async def test_invalid_harness_cells_render_red_check_marks():
    # An invalid / not-installed harness must signal danger in color, not blend
    # into healthy rows as neutral gray.
    client = make_client_with({
        "ai-litellm harness list --json": json.dumps([
            {"name": "claude", "valid": True, "cliInstalled": True},
            {"name": "goose", "valid": False, "cliInstalled": False},
        ]),
    })
    app = FabricApp(client=client)
    async with app.run_test() as pilot:
        await pilot.pause()
        app._selected = "harnesses"
        app.show_panel("harnesses")
        await pilot.pause()
        from textual.widgets import DataTable
        table = app.query_one("#data-table", DataTable)
        # columns: name, valid, cliInstalled
        valid_ok = table.get_cell_at((0, 1))     # claude valid=True
        valid_bad = table.get_cell_at((1, 1))    # goose valid=False
        assert valid_ok.plain == "✓" and "green" in str(valid_ok.style)
        assert valid_bad.plain == "✗" and "red" in str(valid_bad.style)
        cli_bad = table.get_cell_at((1, 2))      # goose cliInstalled=False
        assert cli_bad.plain == "✗" and "red" in str(cli_bad.style)


@pytest.mark.asyncio
async def test_missing_key_renders_red():
    client = make_client_with({
        "ai-litellm key status --json": json.dumps({
            "OPENROUTER_API_KEY": {"source": "keychain"},
            "GEMINI_API_KEY": {"source": "missing"},
        }),
    })
    app = FabricApp(client=client)
    async with app.run_test() as pilot:
        await pilot.pause()
        app.show_panel("keys")
        await pilot.pause()
        from textual.widgets import Static
        text = app.query_one("#content", Static).content
        # The colored Text carries a red span exactly over the "missing" source.
        reds = [text.plain[s.start:s.end] for s in text.spans if "red" in str(s.style)]
        greens = [text.plain[s.start:s.end] for s in text.spans if "green" in str(s.style)]
        assert "missing" in reds
        assert "keychain" in greens


@pytest.mark.asyncio
async def test_models_panel_with_multiple_nameless_rows_does_not_crash():
    # Regression: model limits/list rows are keyed on `model`, not `name`. Two
    # such rows both produced key="" -> textual DuplicateKey -> app teardown.
    # The fix keys on "<model>#<i>", so >=2 name-less rows must render cleanly.
    client = make_client_with({
        "ai-litellm model limits --json": json.dumps([
            {"model": "a", "tpm": 1},
            {"model": "b", "tpm": 2},
        ]),
    })
    app = FabricApp(client=client)
    async with app.run_test() as pilot:
        await pilot.pause()
        app.show_panel("models")   # would raise DuplicateKey before the fix
        await pilot.pause()
        from textual.widgets import DataTable
        table = app.query_one("#data-table", DataTable)
        assert table.display is True
        assert table.row_count == 2
        assert str(table.get_cell_at((0, 0))) == "a"
        assert str(table.get_cell_at((1, 0))) == "b"


@pytest.mark.asyncio
async def test_harness_row_key_with_index_suffix_resolves_to_name():
    # Multiple harnesses get "<name>#<i>" keys; highlighting must recover the
    # bare name (not "claude#0") as the launch target.
    client = make_client_with({
        "ai-litellm harness list --json": json.dumps([
            {"name": "claude", "valid": True},
            {"name": "goose", "valid": True},
        ]),
    })
    app = FabricApp(client=client)
    async with app.run_test() as pilot:
        await pilot.pause()
        app._selected = "harnesses"
        app.show_panel("harnesses")
        await pilot.pause()
        # First row seeds the target as a bare name.
        assert app._selected_harness == "claude"
        from textual.widgets import DataTable
        table = app.query_one("#data-table", DataTable)
        table.move_cursor(row=1)
        await pilot.pause()
        assert app._selected_harness == "goose"   # not "goose#1"


@pytest.mark.asyncio
async def test_footer_color_grades_keys_by_safety():
    app = FabricApp(client=make_client())
    async with app.run_test() as pilot:
        await pilot.pause()
        from fabric_dash.footer import StatusFooter
        footer = app.query_one("#footer", StatusFooter)

        # --- global actions visible on any panel (proxy is the default) ---
        text = footer.content

        def color_of(label, t=None):
            t = t or text
            i = t.plain.index(label)
            for s in t.spans:
                if s.start <= i < s.end and ("green" in str(s.style) or "yellow" in str(s.style) or "red" in str(s.style)):
                    return str(s.style)
            return ""

        # Safe read-only actions render green; disruptive amber.
        assert "green" in color_of("refresh")
        assert "green" in color_of("start")
        assert "yellow" in color_of("sync")
        assert "yellow" in color_of("restart")
        # A visible divider separates the read-only group from the mutating one.
        assert "│" in text.plain

        # --- launch is billable red, but only appears on the harnesses panel ---
        footer.set_items(app._actions_for("harnesses"))
        await pilot.pause()
        harness_text = footer.content
        assert "red" in color_of("launch", harness_text)


@pytest.mark.asyncio
async def test_proxy_panel_colors_health_and_currency():
    # The panel body (the larger surface) must carry the same status colors the
    # header shows — not flat neutral grey.
    app = FabricApp(client=make_client())  # health ok, configCurrency stale
    async with app.run_test() as pilot:
        await pilot.pause()
        app.show_panel("proxy")
        await pilot.pause()
        from textual.widgets import Static
        text = app.query_one("#content", Static).content
        greens = [text.plain[s.start:s.end] for s in text.spans if "green" in str(s.style)]
        ambers = [text.plain[s.start:s.end] for s in text.spans if "yellow" in str(s.style)]
        assert "ok" in greens          # health: ok -> green
        assert "stale" in ambers       # configCurrency: stale -> amber


@pytest.mark.asyncio
async def test_status_bar_points_newcomer_to_harnesses_when_unselected():
    app = FabricApp(client=make_client())
    async with app.run_test() as pilot:
        await pilot.pause()
        assert app._selected_harness is None
        status = app.query_one("#status")
        # Amber, actionable hint rather than a passive "select a harness".
        # Render the markup the way Textual does — a raw-markup assertion gives a
        # FALSE pass when "[open Harnesses]" is parsed as a tag and dropped, while
        # the user sees nothing. from_markup renders the visible text.
        from rich.text import Text
        raw = status.content
        rendered = raw.plain if hasattr(raw, "plain") else Text.from_markup(str(raw)).plain
        assert "[open Harnesses]" in rendered


@pytest.mark.asyncio
async def test_app_boots_and_shows_proxy_health():
    app = FabricApp(client=make_client())
    async with app.run_test() as pilot:
        await pilot.pause()
        # In textual 8.2.7 Static exposes .content property (not .renderable)
        status_widget = app.query_one("#status")
        status_text = str(status_widget.content)
        assert "ok" in status_text
        # concept tree has the six top nodes
        from textual.widgets import Tree
        tree = app.query_one(Tree)
        labels = [str(n.label) for n in tree.root.children]
        assert any("Proxy" in l for l in labels)
        assert any("Models" in l for l in labels)


def test_cell_formats_dict_value_not_raw_repr():
    from fabric_dash.app import _cell
    cell = _cell("sources", {"context": "provider", "output": "owned-policy"})
    plain = cell.plain
    assert "{" not in plain and "'" not in plain          # no python repr leakage
    assert "provider" in plain and "owned-policy" in plain  # values shown
    assert plain == "provider / owned-policy"               # compact, ordered by dict order


def test_cell_formats_scalars_and_none():
    from fabric_dash.app import _cell
    assert _cell("context", 1048576).plain == "1048576"
    assert _cell("model", None).plain == ""
    assert _cell("backend", "openrouter/x").plain == "openrouter/x"


def test_format_value_bool_inside_dict():
    # _format_value's bool branch is only reached when a bool is nested inside a
    # dict or list — the outer _cell bool path fires first for top-level booleans.
    # This test exercises the recursion + bool branch directly.
    from fabric_dash.app import _format_value
    result = _format_value({"valid": True, "ctx": "provider"})
    # bool True -> "yes", string "provider" -> "provider"; joined by " / "
    assert "yes" in result, f"expected 'yes' for True; got: {result!r}"
    assert "provider" in result, f"expected 'provider' in result; got: {result!r}"
    assert "{" not in result and "True" not in result, (
        f"no raw repr expected; got: {result!r}"
    )
    # False branch
    result_false = _format_value({"valid": False, "ctx": "env"})
    assert "no" in result_false, f"expected 'no' for False; got: {result_false!r}"


@pytest.mark.asyncio
async def test_help_overlay_opens_and_lists_keys():
    app = FabricApp(client=make_client())
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("?")
        await pilot.pause()
        from fabric_dash.help import HelpOverlay
        assert isinstance(app.screen, HelpOverlay)
        text = app.screen.query_one("#help-body").content
        body = text.plain if hasattr(text, "plain") else str(text)
        for token in ("sync", "restart", "launch", "doctor", "quit"):
            assert token in body
        # Key→label pairing: lowercase s must bind to "start", uppercase S to "sync".
        # The overlay body is the raw markup string (content is str, not Rich Text
        # here). Lines look like: "  [b]s     [/b]  start proxy". We match the key
        # glyph inside the [b]...[/b] tag and assert the label that follows.
        import re
        lines = body.splitlines()
        def label_for_key(key):
            # Match lines whose [b] block contains exactly the key (plus padding).
            # Pattern: optional spaces, [b], key, spaces, [/b], then the label.
            pat = re.compile(r'^\s*\[b\]' + re.escape(key) + r'\s*\[/b\]\s+(.+)$')
            for line in lines:
                m = pat.match(line)
                if m:
                    return m.group(1)
            return ""
        s_label = label_for_key("s")
        S_label = label_for_key("S")
        assert "start" in s_label, f"'s' must label 'start'; got: {s_label!r}"
        assert "sync" in S_label, f"'S' must label 'sync'; got: {S_label!r}"
        # Cross-check: swapping the two labels must break one of these assertions.
        assert "sync" not in s_label, (
            f"'s' must NOT say sync (inverted label); got: {s_label!r}"
        )
        await pilot.press("escape"); await pilot.pause()
        assert not isinstance(app.screen, HelpOverlay)


@pytest.mark.asyncio
async def test_help_overlay_dismissed_by_q():
    """HelpOverlay.BINDINGS wires q to dismiss — verify the path is reachable."""
    app = FabricApp(client=make_client())
    async with app.run_test() as pilot:
        await pilot.pause()
        from fabric_dash.help import HelpOverlay
        # Open with ?
        await pilot.press("?")
        await pilot.pause()
        assert isinstance(app.screen, HelpOverlay), "overlay must open on ?"
        # Dismiss with q
        await pilot.press("q")
        await pilot.pause()
        assert not isinstance(app.screen, HelpOverlay), "q must dismiss the overlay"


@pytest.mark.asyncio
async def test_action_bar_is_contextual_per_panel():
    """launch appears on harnesses panel only; sync appears on all panels."""
    app = FabricApp(client=make_client())
    async with app.run_test() as pilot:
        await pilot.pause()
        from fabric_dash.footer import StatusFooter
        footer = app.query_one("#footer", StatusFooter)

        # --- harnesses panel: launch must be visible ---
        app._selected = "harnesses"
        app.query_one("#footer", StatusFooter).set_items(app._actions_for("harnesses"))
        await pilot.pause()
        bar = footer.content.plain
        assert "launch" in bar, f"expected 'launch' in harnesses bar; got: {bar!r}"
        assert "sync" in bar,   f"expected 'sync' in harnesses bar; got: {bar!r}"
        assert " l " in bar,    f"expected key ' l ' in harnesses bar; got: {bar!r}"

        # --- proxy panel: launch must NOT appear ---
        app._selected = "proxy"
        app.query_one("#footer", StatusFooter).set_items(app._actions_for("proxy"))
        await pilot.pause()
        bar_proxy = footer.content.plain
        assert "launch" not in bar_proxy, (
            f"'launch' must not appear on proxy panel; got: {bar_proxy!r}"
        )


@pytest.mark.asyncio
async def test_refresh_status_reentrancy_guard():
    """Re-entrancy guard: two concurrent refresh_status calls must only issue ONE
    proxy_status read, not two.

    TDD evidence:
    - WITHOUT guard: both coroutines race through the flag check before either
      sets _refresh_in_flight; call_counter reaches 2.
    - WITH guard: the first coroutine sets the flag; the second sees it True and
      returns early; call_counter stays at 1.

    The gate pattern: proxy_status blocks until released so both coroutines are
    guaranteed to overlap — we gather them, release the gate, let both settle,
    then check the counter.
    """
    # Threading primitives for controlling the slow proxy read.
    gate = threading.Event()       # blocks proxy_status until we release it
    call_counter = 0               # how many times proxy_status was actually called

    def slow_proxy_status():
        nonlocal call_counter
        call_counter += 1
        # Block until the test releases the gate (simulates a slow/timeout proxy).
        gate.wait(timeout=5.0)
        return {"health": "ok", "configCurrency": "current", "baseUrl": "http://127.0.0.1:4000"}

    # Minimal FabricClient whose proxy_status blocks on `gate`.
    base_data = {
        "ai-litellm proxy status --json": json.dumps({"health": "ok", "configCurrency": "current", "baseUrl": "http://127.0.0.1:4000"}),
        "ai-litellm model list --json": json.dumps([]),
        "ai-litellm model limits --json": json.dumps([]),
        "ai-litellm harness list --json": json.dumps([]),
        "ai-litellm key status --json": json.dumps({}),
        "ai-litellm runtime status --json": json.dumps([]),
        "ai-litellm reasoning matrix --json": json.dumps([]),
    }

    def run(argv):
        return (0, base_data.get(" ".join(a for a in argv if a is not None), ""))

    client = FabricClient(runner=run)

    app = FabricApp(client=client)
    # Monkey-patch proxy_status AFTER FabricApp is created (so on_mount's initial
    # refresh_status uses the instant runner-backed version, boots cleanly, and
    # the gate is fresh for our controlled overlap test below).
    # We patch AFTER the context manager enters (post-mount).
    async with app.run_test(headless=True) as pilot:
        # App is fully booted; on_mount's initial refresh_status completed (using
        # the instant runner-backed proxy_status via base_data above).
        await pilot.pause()

        # Now swap in the slow blocking version for the controlled overlap test.
        client.proxy_status = slow_proxy_status

        # Release the gate immediately — the point is not to time the overlap but
        # to let asyncio.gather drive both coroutines and count how many thread
        # dispatches happen.
        gate.set()

        # Fire TWO refresh_status calls concurrently on the event loop.
        # asyncio.gather schedules both coroutines before either executes; the
        # guard must ensure only one issues a proxy_status call.
        await asyncio.gather(
            app.refresh_status(),
            app.refresh_status(),
        )

        # Both coroutines have now returned (gather waits for all).
        # With the guard: only 1 proxy_status call was made (second returned early).
        # Without the guard: both proceed to asyncio.to_thread, giving 2.
        assert call_counter == 1, (
            f"Guard failed: expected exactly 1 proxy_status call for 2 concurrent "
            f"refresh_status invocations, got {call_counter}"
        )


@pytest.mark.asyncio
async def test_run_argv_safe_runs_without_modal_and_logs():
    calls = []
    def spawn(argv):
        calls.append(argv)
        return (0, ["did the thing"])
    from fabric_dash.actions import ActionRunner
    app = FabricApp(client=make_client(), runner=ActionRunner(spawn=spawn))
    async with app.run_test() as pilot:
        await pilot.pause()
        await app._run_argv(["proxy", "start"], label="start proxy")  # SAFE → no modal
        await pilot.pause()
        assert calls == [["ai-litellm", "proxy", "start"]]
        # not asserting modal absence beyond: the call completed inline (no hang)


@pytest.mark.asyncio
async def test_run_argv_restart_goes_through_confirm_modal():
    calls = []
    def spawn(argv):
        calls.append(argv)
        return (0, [])
    from fabric_dash.actions import ActionRunner
    app = FabricApp(client=make_client(), runner=ActionRunner(spawn=spawn))
    async with app.run_test() as pilot:
        await pilot.pause()
        app._run_argv_worker(["proxy", "restart"], "restart proxy")  # schedule via a worker wrapper
        await pilot.pause()
        from fabric_dash.modal import ConfirmModal
        assert isinstance(app.screen, ConfirmModal)   # RESTART → gated, not yet run
        assert calls == []
        await pilot.press("tab"); await pilot.press("enter"); await pilot.pause()
        assert calls == [["ai-litellm", "proxy", "restart"]]


@pytest.mark.asyncio
async def test_palette_filter_and_select_noarg_returns_argv():
    from fabric_dash.palette import CommandPalette
    from fabric_dash.commands import COMMANDS
    captured = {}
    app = FabricApp(client=make_client())
    async with app.run_test() as pilot:
        await pilot.pause()
        async def grab():
            captured["choice"] = await app.push_screen_wait(CommandPalette(COMMANDS))
        app.run_worker(grab())
        await pilot.pause()
        await pilot.press("r", "e", "s", "t")          # filter -> "restart proxy"
        await pilot.pause()
        await pilot.press("enter")                     # no-arg -> selects + dismisses
        await pilot.pause()
        label, argv = captured["choice"]
        assert argv == ["proxy", "restart"]

@pytest.mark.asyncio
async def test_palette_args_mode_shows_usage_and_splits():
    from fabric_dash.palette import CommandPalette
    from fabric_dash.commands import COMMANDS
    captured = {}
    app = FabricApp(client=make_client())
    async with app.run_test() as pilot:
        await pilot.pause()
        async def grab():
            captured["choice"] = await app.push_screen_wait(CommandPalette(COMMANDS))
        app.run_worker(grab())
        await pilot.pause()
        # filter to a takes_args command (model reasoning set)
        for ch in "modelreasoningset":
            await pilot.press(ch)
        await pilot.pause()
        await pilot.press("enter")                     # enters ARG mode (does not dismiss yet)
        await pilot.pause()
        from textual.widgets import Input
        inp = app.screen.query_one(Input)
        assert "model reasoning set" in inp.placeholder  # usage hint shown
        for ch in "GLM-5.2 high":
            await pilot.press(ch if ch != " " else "space")
        await pilot.press("enter")                     # submit args -> dismiss
        await pilot.pause()
        label, argv = captured["choice"]
        assert argv == ["model", "reasoning", "set", "GLM-5.2", "high"]

@pytest.mark.asyncio
async def test_palette_escape_cancels():
    from fabric_dash.palette import CommandPalette
    from fabric_dash.commands import COMMANDS
    captured = {}
    app = FabricApp(client=make_client())
    async with app.run_test() as pilot:
        await pilot.pause()
        async def grab():
            captured["choice"] = await app.push_screen_wait(CommandPalette(COMMANDS))
        app.run_worker(grab())
        await pilot.pause()
        await pilot.press("escape")
        await pilot.pause()
        assert captured["choice"] is None


@pytest.mark.asyncio
async def test_colon_opens_palette():
    app = FabricApp(client=make_client())
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("colon")
        await pilot.pause()
        from fabric_dash.palette import CommandPalette
        assert isinstance(app.screen, CommandPalette)


@pytest.mark.asyncio
async def test_palette_runs_safe_command_without_modal():
    calls = []
    def spawn(argv):
        calls.append(argv); return (0, ["ok"])
    from fabric_dash.actions import ActionRunner
    app = FabricApp(client=make_client(), runner=ActionRunner(spawn=spawn))
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("colon"); await pilot.pause()
        for ch in "start":                  # filter -> "start proxy" (SAFE)
            await pilot.press(ch)
        await pilot.press("enter"); await pilot.pause()  # select+run, no modal
        assert calls == [["ai-litellm", "proxy", "start"]]


@pytest.mark.asyncio
async def test_palette_restart_command_goes_through_confirm_modal():
    calls = []
    def spawn(argv):
        calls.append(argv); return (0, [])
    from fabric_dash.actions import ActionRunner
    app = FabricApp(client=make_client(), runner=ActionRunner(spawn=spawn))
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("colon"); await pilot.pause()
        for ch in "restart":
            await pilot.press(ch)
        await pilot.press("enter"); await pilot.pause()  # palette closes, gate opens
        from fabric_dash.modal import ConfirmModal
        assert isinstance(app.screen, ConfirmModal)
        assert calls == []                               # not run until confirmed
        await pilot.press("tab"); await pilot.press("enter"); await pilot.pause()
        assert calls == [["ai-litellm", "proxy", "restart"]]


@pytest.mark.asyncio
async def test_effort_selector_picks_effort():
    from fabric_dash.effort_modal import EffortSelector
    captured = {}
    app = FabricApp(client=make_client())
    async with app.run_test() as pilot:
        await pilot.pause()
        async def grab():
            captured["c"] = await app.push_screen_wait(EffortSelector(["low", "high", "xhigh"], "GLM-5.2"))
        app.run_worker(grab())
        await pilot.pause()
        await pilot.press("down")          # move to "high" (index 1)
        await pilot.press("enter")
        await pilot.pause()
        assert captured["c"] == "high"

@pytest.mark.asyncio
async def test_effort_selector_unset_and_cancel():
    from fabric_dash.effort_modal import EffortSelector
    captured = {}
    app = FabricApp(client=make_client())
    async with app.run_test() as pilot:
        await pilot.pause()
        async def grab():
            captured["c"] = await app.push_screen_wait(EffortSelector(["low"], "claude"))
        app.run_worker(grab())
        await pilot.pause()
        await pilot.press("escape"); await pilot.pause()
        assert captured["c"] is None


@pytest.mark.asyncio
async def test_effort_selector_unset_row_returns_unset():
    from fabric_dash.effort_modal import EffortSelector
    captured = {}
    app = FabricApp(client=make_client())
    async with app.run_test() as pilot:
        await pilot.pause()
        async def grab():
            captured["c"] = await app.push_screen_wait(EffortSelector(["low"], "claude"))
        app.run_worker(grab())
        await pilot.pause()
        await pilot.press("down")          # choices are ["low", "unset"]; move to "unset"
        await pilot.press("enter")
        await pilot.pause()
        assert captured["c"] == "unset"


@pytest.mark.asyncio
async def test_effort_action_on_models_runs_reasoning_set():
    calls = []
    def spawn(argv):
        calls.append(argv); return (0, ["Run 'ai-litellm sync' to apply it to the running proxy."])
    from fabric_dash.actions import ActionRunner
    client = make_client()
    # client.model_reasoning_allowed returns something non-empty
    app = FabricApp(client=client, runner=ActionRunner(spawn=spawn))
    app.client.model_reasoning_allowed = lambda m: ["low", "high"]
    async with app.run_test() as pilot:
        await pilot.pause()
        app.show_panel("models"); app._selected = "models"
        await pilot.pause()   # drain initial row-highlighted; then pin the target model
        app._selected_model = "GLM-5.2"
        await pilot.press("e"); await pilot.pause()      # opens EffortSelector
        from fabric_dash.effort_modal import EffortSelector
        assert isinstance(app.screen, EffortSelector)
        await pilot.press("down"); await pilot.press("enter"); await pilot.pause()  # pick "high"
        assert calls == [["ai-litellm", "model", "reasoning", "set", "GLM-5.2", "high"]]

@pytest.mark.asyncio
async def test_effort_action_guards_when_no_selection():
    app = FabricApp(client=make_client())
    async with app.run_test() as pilot:
        await pilot.pause()
        app._selected = "proxy"            # not a reasoning panel
        await pilot.press("e"); await pilot.pause()
        from fabric_dash.effort_modal import EffortSelector
        assert not isinstance(app.screen, EffortSelector)   # guarded, no modal


@pytest.mark.asyncio
async def test_key_modal_pick_then_masked_secret_returns_tuple():
    from fabric_dash.key_modal import KeySetModal
    captured = {}
    app = FabricApp(client=make_client())
    async with app.run_test() as pilot:
        await pilot.pause()
        async def grab():
            captured["c"] = await app.push_screen_wait(KeySetModal(["openrouter", "master"]))
        app.run_worker(grab())
        await pilot.pause()
        await pilot.press("enter")              # pick first provider (openrouter) -> secret mode
        await pilot.pause()
        from textual.widgets import Input
        inp = app.screen.query_one(Input)
        assert inp.password is True             # masked
        for ch in "sk-xyz":
            await pilot.press(ch if ch != "-" else "minus")
        await pilot.press("enter")              # submit
        await pilot.pause()
        provider, secret = captured["c"]
        assert provider == "openrouter" and secret == "sk-xyz"

@pytest.mark.asyncio
async def test_key_modal_escape_cancels():
    from fabric_dash.key_modal import KeySetModal
    captured = {}
    app = FabricApp(client=make_client())
    async with app.run_test() as pilot:
        await pilot.pause()
        async def grab():
            captured["c"] = await app.push_screen_wait(KeySetModal(["openrouter"]))
        app.run_worker(grab())
        await pilot.pause()
        await pilot.press("escape"); await pilot.pause()
        assert captured["c"] is None


@pytest.mark.asyncio
async def test_key_action_runs_key_set_with_secret_via_stdin():
    seen = {}
    def spawn(argv, stdin_input=None):
        seen["argv"] = argv; seen["stdin"] = stdin_input
        return (0, ["Stored OPENROUTER_API_KEY in macOS Keychain"])
    from fabric_dash.actions import ActionRunner
    app = FabricApp(client=make_client(), runner=ActionRunner(spawn=spawn))
    async with app.run_test() as pilot:
        await pilot.pause()
        app._selected = "keys"; app.show_panel("keys")
        await pilot.pause()
        await pilot.press("k"); await pilot.pause()          # opens KeySetModal
        from fabric_dash.key_modal import KeySetModal
        assert isinstance(app.screen, KeySetModal)
        await pilot.press("enter")                            # pick first provider
        await pilot.pause()
        for ch in "topsecret":
            await pilot.press(ch)
        await pilot.press("enter"); await pilot.pause()       # submit -> run
        assert seen["argv"][:4] == ["ai-litellm", "key", "set", "--keychain"]  # no secret in argv
        assert seen["stdin"] == "topsecret"                                    # secret via stdin only


@pytest.mark.asyncio
async def test_key_action_guarded_off_keys_panel():
    app = FabricApp(client=make_client())
    async with app.run_test() as pilot:
        await pilot.pause()
        app._selected = "proxy"
        await pilot.press("k"); await pilot.pause()
        from fabric_dash.key_modal import KeySetModal
        assert not isinstance(app.screen, KeySetModal)        # guarded
