# fabric TUI Actions & Safety — Implementation Plan (3 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add actions to the `fabric` TUI — sync/restart/start/stop, doctor-all, and harness launch — each gated by a safety classification so restart-causing and billable operations require an explicit confirm modal that states the consequence.

**Architecture:** A pure `safety.py` classifies every action into SAFE / RESTART / BILLABLE / DESTRUCTIVE. An injectable `ActionRunner` executes commands and streams output into a results log. A `ConfirmModal` screen gates any non-SAFE action. Harness launch hands the terminal over by exiting the app and exec-ing the launch command in `__main__`.

**Tech Stack:** Python 3, Textual (`ModalScreen`, `RichLog`, bindings), pytest + Textual `Pilot`.

**Depends on:** Plan 2 (`FabricApp`, `FabricClient`, package + packaging). This plan adds `safety.py`, `actions.py`, modal + action bar, and launch handoff.

## Global Constraints

- the TUI calls existing `ai-litellm` commands; it never re-implements their logic. (spec §2, §4)
- every restart-causing (`sync`, `proxy restart/stop`) and billable (`*probe`, cloud `harness launch`) action MUST pass through a confirm modal that names the consequence; SAFE actions (start, doctor) run without confirm. (spec §5, §6)
- `uninstall` is DESTRUCTIVE → excluded from v1 action bar (require typing the full command in a real shell). (spec §6, §7)
- auto-refresh remains read-only; no action ever auto-fires. (spec §5.1)
- tests make zero real provider/network calls; `ActionRunner` is injected. (spec §10)

---

## File Structure

- Create: `config/ai-litellm/fabric_dash/safety.py` — classification + action registry.
- Create: `config/ai-litellm/fabric_dash/actions.py` — `ActionRunner`.
- Create: `config/ai-litellm/fabric_dash/modal.py` — `ConfirmModal`.
- Modify: `config/ai-litellm/fabric_dash/app.py` — action bar bindings, results log, launch handoff.
- Modify: `config/ai-litellm/fabric_dash/__main__.py` — exec the launch command after the app exits.
- Create/extend: `config/ai-litellm/fabric_dash/tests/test_safety.py`, `tests/test_actions_app.py`.

---

## Task 1: Safety classification

**Files:**
- Create: `config/ai-litellm/fabric_dash/safety.py`, `tests/test_safety.py`

**Interfaces:**
- Produces: enum-like constants `SAFE, RESTART, BILLABLE, DESTRUCTIVE`; `classify(argv: list[str]) -> str`; `ACTIONS: list[Action]` where `Action = namedtuple("Action", "key label argv grade needs_confirm consequence")` for the action bar (sync/restart/start/stop/doctor-all).

- [ ] **Step 1: Write the failing test** — `config/ai-litellm/fabric_dash/tests/test_safety.py`:

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd config/ai-litellm && python3 -m pytest fabric_dash/tests/test_safety.py -q`
Expected: FAIL — `fabric_dash.safety` does not exist.

- [ ] **Step 3: Create `safety.py`**:

```python
"""Classify ai-litellm actions by operational risk. Pure; no side effects."""
from __future__ import annotations
from collections import namedtuple

SAFE = "safe"
RESTART = "restart"
BILLABLE = "billable"
DESTRUCTIVE = "destructive"

Action = namedtuple("Action", "key label argv grade needs_confirm consequence")


def classify(argv: list) -> str:
    a = [x for x in argv if x]
    joined = " ".join(a)
    if a and a[0] == "uninstall":
        return DESTRUCTIVE
    if "probe" in a or joined.endswith("route check") or "check" == (a[-1] if a else ""):
        # probes and route check issue real requests
        if "probe" in a or joined.endswith("route check"):
            return BILLABLE
    if joined in ("sync", "proxy sync") or joined.startswith("proxy restart") \
            or joined.startswith("proxy stop") or a[:1] == ["sync"]:
        return RESTART
    return SAFE


ACTIONS = [
    Action("s", "sync", ["sync"], RESTART, True,
           "sync regenerates configs and restarts the proxy — this can interrupt active LiteLLM sessions."),
    Action("R", "restart", ["proxy", "restart"], RESTART, True,
           "restarting the proxy interrupts active LiteLLM-backed sessions."),
    Action("S", "start", ["proxy", "start"], SAFE, False, ""),
    Action("x", "stop", ["proxy", "stop"], RESTART, True,
           "stopping the proxy interrupts active LiteLLM-backed sessions."),
    Action("d", "doctor", ["proxy", "doctor"], SAFE, False, ""),
]
```

> Note: keep `classify` conservative — when unsure, prefer the higher-risk grade. The `route probe`/`model probe`/`reasoning probe`/`context probe`/`route check` set is the BILLABLE list from spec §6; if a verb is added later, default-billable any verb containing `probe`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd config/ai-litellm && python3 -m pytest fabric_dash/tests/test_safety.py -q`
Expected: PASS (2 passed).

- [ ] **Step 5: Commit**

```bash
git add config/ai-litellm/fabric_dash/safety.py config/ai-litellm/fabric_dash/tests/test_safety.py
git commit -m "feat(dash): safety classification for actions"
```

---

## Task 2: ActionRunner

**Files:**
- Create: `config/ai-litellm/fabric_dash/actions.py`

**Interfaces:**
- Produces: `ActionRunner(spawn=None)` with `run(argv, on_line) -> int` — prepends `ai-litellm`, streams each stdout/stderr line to `on_line(str)`, returns exit code. `spawn` is injectable `Callable[[list[str]], tuple[int, list[str]]]` for tests.

- [ ] **Step 1: Write the failing test** — append to `config/ai-litellm/fabric_dash/tests/test_actions_app.py`:

```python
from fabric_dash.actions import ActionRunner

def test_runner_streams_and_returns_rc():
    def spawn(argv):
        assert argv[0] == "ai-litellm"
        return (0, ["line1", "line2"])
    seen = []
    rc = ActionRunner(spawn=spawn).run(["proxy", "start"], on_line=seen.append)
    assert rc == 0
    assert seen == ["line1", "line2"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd config/ai-litellm && python3 -m pytest fabric_dash/tests/test_actions_app.py::test_runner_streams_and_returns_rc -q`
Expected: FAIL — `fabric_dash.actions` does not exist.

- [ ] **Step 3: Create `actions.py`**:

```python
"""Execute ai-litellm actions, streaming output. Never classifies — callers
gate via safety.classify + ConfirmModal first."""
from __future__ import annotations
import subprocess
from typing import Callable, Optional


def _default_spawn(argv: list) -> tuple:
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=600)
        lines = (p.stdout + p.stderr).splitlines()
        return (p.returncode, lines)
    except Exception as e:
        return (1, [f"error: {e}"])


class ActionRunner:
    def __init__(self, spawn: Optional[Callable] = None, binary: str = "ai-litellm"):
        self._spawn = spawn or _default_spawn
        self._bin = binary

    def run(self, argv: list, on_line: Callable[[str], None]) -> int:
        rc, lines = self._spawn([self._bin, *argv])
        for ln in lines:
            on_line(ln)
        return rc
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd config/ai-litellm && python3 -m pytest fabric_dash/tests/test_actions_app.py::test_runner_streams_and_returns_rc -q`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add config/ai-litellm/fabric_dash/actions.py config/ai-litellm/fabric_dash/tests/test_actions_app.py
git commit -m "feat(dash): ActionRunner streaming executor"
```

---

## Task 3: ConfirmModal + action bar with confirm gate

**Files:**
- Create: `config/ai-litellm/fabric_dash/modal.py`
- Modify: `config/ai-litellm/fabric_dash/app.py`
- Test: `config/ai-litellm/fabric_dash/tests/test_actions_app.py`

**Interfaces:**
- Consumes: `safety.classify`, `safety.ACTIONS`, `ActionRunner`.
- Produces: `ConfirmModal(consequence: str)` → `ModalScreen[bool]` ([Confirm]/[Cancel]); `FabricApp` gains a results `RichLog#results`, an `on_action(action)` that confirms-then-runs, and accepts `runner=` in `__init__`. **Invariant: a `needs_confirm` action never reaches the runner unless the modal returns True.**

- [ ] **Step 1: Write the failing test** — append to `tests/test_actions_app.py`:

```python
import json, pytest
from fabric_dash.app import FabricApp
from fabric_dash.client import FabricClient

def _client():
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
    from fabric_dash.actions import ActionRunner
    app = FabricApp(client=_client(), runner=ActionRunner(spawn=spawn))
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("s")          # sync = RESTART, needs confirm
        await pilot.pause()
        assert calls == []              # nothing ran yet — modal is up
        await pilot.press("escape")     # cancel
        await pilot.pause()
        assert calls == []              # cancelled → still nothing
        await pilot.press("s")
        await pilot.pause()
        await pilot.press("enter")      # confirm
        await pilot.pause()
        assert calls and calls[0][:2] == ["ai-litellm", "sync"]

@pytest.mark.asyncio
async def test_safe_action_runs_without_modal():
    calls = []
    from fabric_dash.actions import ActionRunner
    app = FabricApp(client=_client(), runner=ActionRunner(spawn=lambda a: (calls.append(a) or (0, ["ok"]))))
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("S")          # start = SAFE
        await pilot.pause()
        assert calls and calls[0][:2] == ["ai-litellm", "proxy"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd config/ai-litellm && python3 -m pytest fabric_dash/tests/test_actions_app.py -q`
Expected: FAIL — `fabric_dash.modal` missing and `FabricApp` lacks action bindings/`runner`.

- [ ] **Step 3: Create `modal.py`**:

```python
from __future__ import annotations
from textual.app import ComposeResult
from textual.screen import ModalScreen
from textual.containers import Vertical, Horizontal
from textual.widgets import Static, Button


class ConfirmModal(ModalScreen):
    BINDINGS = [("escape", "cancel", "Cancel"), ("enter", "confirm", "Confirm")]

    def __init__(self, consequence: str):
        super().__init__()
        self._consequence = consequence

    def compose(self) -> ComposeResult:
        with Vertical(id="confirm-box"):
            yield Static(f"⚠ {self._consequence}", id="confirm-msg")
            with Horizontal():
                yield Button("Confirm", id="confirm-yes", variant="warning")
                yield Button("Cancel", id="confirm-no", variant="primary")

    def action_confirm(self) -> None:
        self.dismiss(True)

    def action_cancel(self) -> None:
        self.dismiss(False)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "confirm-yes")
```

- [ ] **Step 4: Wire actions into `app.py`** — add to `FabricApp`:
  1. `__init__(self, client=None, runner=None)` storing `self.runner = runner or ActionRunner()`.
  2. Imports: `from .safety import ACTIONS, classify, SAFE`; `from .actions import ActionRunner`; `from .modal import ConfirmModal`; `from textual.widgets import RichLog`.
  3. Build `BINDINGS` to include each action: append `(a.key, f"do_{a.key}", a.label)` for `a in ACTIONS` plus the existing quit/refresh.
  4. Add a results log to `compose` (below `#content` or in a bottom dock): `yield RichLog(id="results", highlight=False, markup=True)`.
  5. Add a single dispatcher and per-key action methods:

```python
def _action_by_key(self, key: str):
    for a in ACTIONS:
        if a.key == key:
            return a
    return None

async def _run_action(self, key: str) -> None:
    a = self._action_by_key(key)
    if a is None:
        return
    if a.needs_confirm:
        ok = await self.push_screen_wait(ConfirmModal(a.consequence))
        if not ok:
            self.query_one("#results", RichLog).write(f"[dim]cancelled: {a.label}[/]")
            return
    log = self.query_one("#results", RichLog)
    log.write(f"$ ai-litellm {' '.join(a.argv)}")
    rc = self.runner.run(list(a.argv), on_line=lambda ln: log.write(ln))
    log.write(f"[{'green' if rc == 0 else 'red'}]exit {rc}[/]")
    self.refresh_status()
```

  6. Generate the `action_do_<key>` methods. Because Textual maps binding action names to `action_<name>` methods, add for each action key a thin method, e.g.:

```python
async def action_do_s(self) -> None: await self._run_action("s")
async def action_do_R(self) -> None: await self._run_action("R")
async def action_do_S(self) -> None: await self._run_action("S")
async def action_do_x(self) -> None: await self._run_action("x")
async def action_do_d(self) -> None: await self._run_action("d")
```

> Note: keep these five thin methods explicit (not metaprogrammed) so a fresh reader sees every bound action. They must match the keys in `safety.ACTIONS` exactly.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd config/ai-litellm && python3 -m pytest fabric_dash/tests/ -q`
Expected: PASS — including `test_restart_action_blocked_until_confirm` and `test_safe_action_runs_without_modal`.

- [ ] **Step 6: Commit**

```bash
git add config/ai-litellm/fabric_dash/modal.py config/ai-litellm/fabric_dash/app.py config/ai-litellm/fabric_dash/tests/test_actions_app.py
git commit -m "feat(dash): confirm modal gating restart/billable actions"
```

---

## Task 4: Harness launch handoff

**Files:**
- Modify: `config/ai-litellm/fabric_dash/app.py`, `__main__.py`
- Test: `config/ai-litellm/fabric_dash/tests/test_actions_app.py`

**Interfaces:**
- Produces: a `launch` binding (`l`) that picks the tree-selected harness (or first harness), confirms if cloud-backed (BILLABLE), then `self.exit(result=("launch", [harness]))`. `__main__.main()` inspects the app's return and execs `ai-litellm harness launch <harness>` so the harness owns the terminal (a TUI can't host an interactive child cleanly).

- [ ] **Step 1: Write the failing test** — append to `tests/test_actions_app.py`:

```python
@pytest.mark.asyncio
async def test_launch_exits_with_handoff():
    app = FabricApp(client=_client())
    async with app.run_test() as pilot:
        await pilot.pause()
        app._selected_harness = "claude"   # simulate selection
        await pilot.press("l")
        await pilot.pause()
        await pilot.press("enter")          # confirm billable
        await pilot.pause()
    assert app.return_value == ("launch", ["claude"])
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd config/ai-litellm && python3 -m pytest fabric_dash/tests/test_actions_app.py::test_launch_exits_with_handoff -q`
Expected: FAIL — no `l` binding / no handoff.

- [ ] **Step 3: Add launch to `app.py`**:
  1. Add `("l", "launch", "Launch")` to `BINDINGS`; init `self._selected_harness = "claude"`; set it when a harness leaf is selected in `on_tree_node_selected` (when `node_id == "harnesses"` expand to per-harness leaves, or track the harness chosen — minimally default to "claude").
  2. Add:

```python
async def action_launch(self) -> None:
    harness = getattr(self, "_selected_harness", "claude")
    ok = await self.push_screen_wait(
        ConfirmModal(f"launch {harness}: cloud-backed tiers make billable provider requests."))
    if not ok:
        return
    self.exit(result=("launch", [harness]))
```

- [ ] **Step 4: Exec the handoff in `__main__.py`** — replace the `FabricApp().run()` block:

```python
    app = FabricApp()
    result = app.run()
    if isinstance(result, tuple) and result and result[0] == "launch":
        import os
        harness = result[1][0]
        os.execvp("ai-litellm", ["ai-litellm", "harness", "launch", harness])
    return 0
```

> Note: `os.execvp` replaces the process so the harness inherits the now-restored terminal. This only runs in real use; tests assert `app.return_value` without exec-ing.

- [ ] **Step 5: Run tests + manual smoke**

Run: `cd config/ai-litellm && python3 -m pytest fabric_dash/tests/ -q` → Expected: PASS (all).
Manual: `fabric`, select Harnesses, press `l`, confirm → TUI exits and the chosen harness launches (billable; cancel to avoid).

- [ ] **Step 6: Commit**

```bash
git add config/ai-litellm/fabric_dash/app.py config/ai-litellm/fabric_dash/__main__.py config/ai-litellm/fabric_dash/tests/test_actions_app.py
git commit -m "feat(dash): harness launch with terminal handoff"
```

---

## Task 5: Footer hints + final check

**Files:**
- Modify: `config/ai-litellm/fabric_dash/app.py`, `scripts/check.zsh`

- [ ] **Step 1: Ensure the Footer shows action keys** — confirm `yield Footer()` is present and bindings carry human labels (they do, from the `(key, action, label)` tuples). Add a one-line legend Static above the footer: `[s]ync [R]estart [S]tart [x]stop [d]octor [l]aunch — ⚠ confirms on restart/billable`.

- [ ] **Step 2: Extend check.zsh** — run the dash test suite as part of structural check (only if pytest+textual present, else note):

```zsh
if python3 -c 'import textual, pytest' >/dev/null 2>&1; then
  ( cd "$repo_root/config/ai-litellm" && python3 -m pytest fabric_dash/tests/ -q ) \
    || { echo "FAIL: fabric_dash tests"; exit 1; }
  echo "ok: fabric_dash tests"
else
  echo "note: skipping fabric_dash tests (textual/pytest not installed)" >&2
fi
```

- [ ] **Step 3: Run the full check**

Run: `./scripts/check.zsh`
Expected: PASS — `ok: fabric_dash tests` (or the skip note) plus all prior `ok` lines.

- [ ] **Step 4: Commit**

```bash
git add config/ai-litellm/fabric_dash/app.py scripts/check.zsh
git commit -m "feat(dash): action legend + wire dash tests into check.zsh"
```

---

## Self-Review

**Spec coverage:** Action bar (sync/restart/start/stop/doctor/launch, spec §5), safety classification SAFE/RESTART/BILLABLE/DESTRUCTIVE (§6), confirm modal naming the consequence for restart/billable (§5, §6), `uninstall` excluded as DESTRUCTIVE (§6, §7), launch handoff (§5 launch flow), no auto-fire of actions (§5.1), zero-network injected-runner tests (§10). The confirm-gate invariant is directly asserted by `test_restart_action_blocked_until_confirm`.

**Placeholder scan:** `> Note:` blocks specify conservative-classification policy, explicit (non-metaprogrammed) action methods, and exec-handoff rationale — all concrete. Every code step is runnable; tests precede implementations.

**Type consistency:** Action keys (`s/R/S/x/d/l`) match across `safety.ACTIONS`, the `action_do_*`/`action_launch` methods, BINDINGS, and tests. `classify` grades (`SAFE/RESTART/BILLABLE/DESTRUCTIVE`) consistent. `FabricApp(client=, runner=)` signature matches Plan 2's `client=` plus this plan's `runner=`. `self.exit(result=("launch",[harness]))` matches `__main__`'s `result[0]=="launch"` handoff.

---

*End of the 3-plan series. Build order: Plan 1 (`--json` foundation) → Plan 2 (TUI core) → Plan 3 (actions & safety). Coordinate with `fix/model-info-full-block` (both touch `config/ai-litellm/lib.zsh`): land that branch first, then rebase the `--json` work on top.*
