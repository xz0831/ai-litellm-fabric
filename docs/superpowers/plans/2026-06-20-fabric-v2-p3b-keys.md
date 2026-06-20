# fabric v2 — P3b: Key Set (masked input) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Set an API key from the `fabric` TUI without the secret ever touching argv, the results log, or `ps`: on the Keys panel press `k`, pick a provider, type the secret into a masked field, and it is piped to `ai-litellm key set --keychain <provider>` via stdin.

**Architecture:** No backend change — `ai_litellm_key_set` already reads the secret from stdin (`read -rs`) when no value argument is given. The TUI gains: an optional `stdin_input` on `ActionRunner.run`/`_run_argv` (the secret goes to the subprocess's stdin, never to the log), a `KeySetModal` (provider picker → masked `Input(password=True)`), and a `k` → `action_key` binding guarded to the Keys panel. Execution reuses the existing gated `_run_argv` path; `key set` classifies SAFE so it runs immediately (the masked submit is the deliberate act).

**Tech Stack:** Python 3 + Textual 8.2.7, pytest + Pilot, package venv.

## Global Constraints

- ALL dash python under the venv: `cd config/ai-litellm && "$HOME/.local/share/ai-litellm-fabric/state/dash-venv/bin/python" -m pytest fabric_dash/tests/ -q`. Branch `feat/fabric-v2-p3b-keys`; do NOT switch branches. (spec §3)
- **No backend / lib.zsh change** — `ai_litellm_key_set` already pipes from stdin via `read -rs` when no value arg is passed (lib.zsh:2613); store with `--keychain` (macOS secure default; existing keys' source). (spec §14)
- **SECURITY (load-bearing):** the secret travels ONLY as `stdin_input` → `subprocess.run(input=...)`. It MUST NEVER appear in argv (argv is `["key","set","--keychain",<provider>]`), in any logged line, or in `ps`. The masked `Input(password=True)` MUST NOT render the secret on screen. No test may print or assert the secret against a log line as *present*. (spec §14)
- **Single risk oracle / gate reuse** — execution flows through the existing `_run_argv` (gate via `safety.classify`); `key set` classifies SAFE → immediate, no new ConfirmModal, no parallel gate. The only addition to `_run_argv` is the `stdin_input` pass-through. (spec §12, §14)
- **Backward compatibility** — existing tests inject 1-argument fake spawns (`lambda argv: (...)`); the new stdin path must NOT break them (call the 2-arg form only when `stdin_input` is provided). (codebase fact)
- No P1/P2/P3 regression. Tests make ZERO real subprocess/network/keychain calls. Validate Textual 8.2.7 APIs and adapt (P1/P2/P3 lesson). (spec §3, §10)

---

## File Structure

- Modify: `config/ai-litellm/fabric_dash/actions.py` — `_default_spawn` + `ActionRunner.run` gain optional `stdin_input`.
- Modify: `config/ai-litellm/fabric_dash/app.py` — `_run_argv` gains `stdin_input`; `k` binding + `action_key`; `_actions_for` adds `[k] set key` on the Keys panel.
- Create: `config/ai-litellm/fabric_dash/key_modal.py` — `KeySetModal` (provider picker → masked input).
- Modify: `config/ai-litellm/fabric_dash/help.py` — `k` keymap entry.
- Test: `tests/test_actions_app.py`, `tests/test_app.py` (additions).

---

## Task 1: stdin support in ActionRunner + `_run_argv` (secret never logged)

**Files:**
- Modify: `config/ai-litellm/fabric_dash/actions.py`
- Modify: `config/ai-litellm/fabric_dash/app.py` (`_run_argv`)
- Test: `config/ai-litellm/fabric_dash/tests/test_actions_app.py`

**Interfaces:**
- Produces: `_default_spawn(argv, stdin_input=None)`; `ActionRunner.run(argv, on_line, stdin_input=None) -> int` (passes the secret to the subprocess's stdin, never to `on_line`); `FabricApp._run_argv(argv, label=None, consequence=None, stdin_input=None)` (forwards `stdin_input` to `runner.run`; logs argv + stdout lines only — never `stdin_input`).

- [ ] **Step 1: Write the failing tests** — append to `tests/test_actions_app.py`:

```python
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
```

- [ ] **Step 2: Run to verify failure**

Run: `cd config/ai-litellm && "$HOME/.local/share/ai-litellm-fabric/state/dash-venv/bin/python" -m pytest fabric_dash/tests/test_actions_app.py -k stdin -q`
Expected: FAIL — `run`/`_default_spawn` don't accept `stdin_input`.

- [ ] **Step 3: Implement in `actions.py`**:

```python
def _default_spawn(argv: list, stdin_input: Optional[str] = None) -> tuple:
    try:
        p = subprocess.run(argv, input=stdin_input, capture_output=True, text=True, timeout=600)
        lines = (p.stdout + p.stderr).splitlines()
        return (p.returncode, lines)
    except Exception as e:
        return (1, [f"error: {e}"])


class ActionRunner:
    def __init__(self, spawn: Optional[Callable] = None, binary: str = "ai-litellm"):
        self._spawn = spawn or _default_spawn
        self._bin = binary

    def run(self, argv: list, on_line: Callable[[str], None], stdin_input: Optional[str] = None) -> int:
        # Call the 2-arg form ONLY when piping stdin, so existing 1-arg fake
        # spawns keep working. The secret (stdin_input) is passed to the child's
        # stdin and is never handed to on_line.
        if stdin_input is None:
            rc, lines = self._spawn([self._bin, *argv])
        else:
            rc, lines = self._spawn([self._bin, *argv], stdin_input)
        for ln in lines:
            on_line(ln)
        return rc
```

- [ ] **Step 4: Thread `stdin_input` through `_run_argv` in `app.py`** — extend the signature and the `to_thread` call:

```python
async def _run_argv(self, argv: list[str], label: str | None = None,
                    consequence: str | None = None, stdin_input: str | None = None) -> None:
    grade = classify(argv)
    name = label or " ".join(argv)
    if grade != SAFE:
        msg = consequence or f"run `ai-litellm {' '.join(argv)}` — a {grade} action."
        ok = await self.push_screen_wait(
            ConfirmModal(msg, title=f"Confirm {name}", grade=grade)
        )
        if not ok:
            self.query_one("#results", RichLog).write(f"[dim]cancelled: {name}[/]")
            return
    log = self.query_one("#results", RichLog)
    log.write(f"$ ai-litellm {' '.join(argv)}")  # argv carries NO secret (it is in stdin_input)
    lines: list[str] = []
    rc = await asyncio.to_thread(self.runner.run, list(argv), lines.append, stdin_input)
    for ln in lines:
        log.write(ln)
    log.write(f"[{'green' if rc == 0 else 'red'}]exit {rc}[/]")
    await self.refresh_status()
```

> Note: the only change is the new `stdin_input` param and passing it as the 3rd arg to `asyncio.to_thread(self.runner.run, ...)`. Everything else (gate, offload, logging) is unchanged. Do NOT log `stdin_input`.

- [ ] **Step 5: Run the full suite**

Run: `cd config/ai-litellm && "$HOME/.local/share/ai-litellm-fabric/state/dash-venv/bin/python" -m pytest fabric_dash/tests/ -q`
Expected: PASS — the 2 new tests + all prior (the 1-arg-spawn compatibility test proves no regression).

- [ ] **Step 6: Commit**

```bash
git add config/ai-litellm/fabric_dash/actions.py config/ai-litellm/fabric_dash/app.py config/ai-litellm/fabric_dash/tests/test_actions_app.py
git commit -m "feat(dash): ActionRunner/_run_argv stdin pass-through (secret never logged)"
```

---

## Task 2: `KeySetModal` (provider picker → masked input)

**Files:**
- Create: `config/ai-litellm/fabric_dash/key_modal.py`
- Modify: `config/ai-litellm/fabric_dash/app.tcss`
- Test: `config/ai-litellm/fabric_dash/tests/test_app.py`

**Interfaces:**
- Produces: `KeySetModal(ModalScreen)` — `__init__(self, providers: list[str])`. Two modes: provider-pick (a `ListView` of the providers) → masked secret (`Input(password=True)`). Dismisses with `(provider: str, secret: str)` on submit, or `None` on escape.

- [ ] **Step 1: Write the failing tests** — append to `tests/test_app.py`:

```python
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
```

- [ ] **Step 2: Run to verify failure**

Run: `cd config/ai-litellm && "$HOME/.local/share/ai-litellm-fabric/state/dash-venv/bin/python" -m pytest fabric_dash/tests/test_app.py -k key_modal -q`
Expected: FAIL — `fabric_dash.key_modal` does not exist.

- [ ] **Step 3: Implement `key_modal.py`**:

```python
"""Key-set picker — choose a provider, then enter the secret in a MASKED field.
Select-only: returns (provider, secret); the app pipes the secret to
`ai-litellm key set --keychain <provider>` via stdin (never argv/log)."""
from __future__ import annotations
from textual import on
from textual.app import ComposeResult
from textual.containers import Vertical
from textual.screen import ModalScreen
from textual.widgets import Input, Label, ListItem, ListView


class KeySetModal(ModalScreen):
    BINDINGS = [("escape", "cancel", "Cancel")]

    def __init__(self, providers: list[str]) -> None:
        super().__init__()
        self._providers = list(providers)
        self._provider: str | None = None

    def compose(self) -> ComposeResult:
        with Vertical(id="key-box"):
            yield Label("set API key — pick provider", id="key-title")
            yield ListView(id="key-list")
            secret = Input(placeholder="paste secret, enter to save", password=True, id="key-secret")
            secret.display = False
            yield secret

    def on_mount(self) -> None:
        lv = self.query_one("#key-list", ListView)
        for p in self._providers:
            lv.append(ListItem(Label(p), name=p))
        if self._providers:
            lv.index = 0
        lv.focus()

    @on(ListView.Selected, "#key-list")
    def _pick(self, event: ListView.Selected) -> None:
        self._provider = event.item.name if event.item is not None else None
        if self._provider is None:
            return
        self.query_one("#key-list", ListView).display = False
        self.query_one("#key-title", Label).update(f"set API key — {self._provider}")
        secret = self.query_one("#key-secret", Input)
        secret.display = True
        secret.focus()

    @on(Input.Submitted, "#key-secret")
    def _submit(self, event: Input.Submitted) -> None:
        if self._provider is not None and event.value:
            self.dismiss((self._provider, event.value))

    def action_cancel(self) -> None:
        self.dismiss(None)
```

> Note: verify against textual 8.2.7 (as P2/P3 did): `Input(password=True)` + `.password`, `ListView.append/index/focus`, `ListItem(name=…)`, `ListView.Selected.item.name`, `Input.Submitted.value`, `@on`. The 2 tests pin the behavior. Read the merged `palette.py`/`effort_modal.py` as working 8.2.7 references.

- [ ] **Step 4: Style in `app.tcss`** — append (mirror the effort/palette modals):

```css
KeySetModal { align: center middle; background: $background 60%; }
#key-box { width: 50; height: auto; padding: 1 2; background: $surface; border: round $warning; }
#key-title { margin-bottom: 1; color: $secondary; }
#key-list { height: auto; max-height: 10; }
```

> Note: the `$warning` (amber) border signals "this writes a credential" — distinct from the read-only/blue modals.

- [ ] **Step 5: Run tests to verify pass**

Run: `cd config/ai-litellm && "$HOME/.local/share/ai-litellm-fabric/state/dash-venv/bin/python" -m pytest fabric_dash/tests/test_app.py -k key_modal -q`
Expected: PASS. Then the full suite — no regression.

- [ ] **Step 6: Commit**

```bash
git add config/ai-litellm/fabric_dash/key_modal.py config/ai-litellm/fabric_dash/app.tcss config/ai-litellm/fabric_dash/tests/test_app.py
git commit -m "feat(dash): KeySetModal (provider picker -> masked secret input)"
```

---

## Task 3: Wire `k` → `action_key` (Keys panel)

**Files:**
- Modify: `config/ai-litellm/fabric_dash/app.py` (BINDINGS, `action_key`, `_actions_for`)
- Modify: `config/ai-litellm/fabric_dash/help.py` (`_KEYS`)
- Test: `config/ai-litellm/fabric_dash/tests/test_app.py`

**Interfaces:**
- Consumes: `KeySetModal` (Task 2), `_run_argv(..., stdin_input=...)` (Task 1), `client.key_status()` (existing — returns `{provider: {...}}`), the Keys panel node id `"keys"`.
- Produces: `action_key` (a `@work` worker).

- [ ] **Step 1: Write the failing tests** — append to `tests/test_app.py`:

```python
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
```

- [ ] **Step 2: Run to verify failure**

Run: `cd config/ai-litellm && "$HOME/.local/share/ai-litellm-fabric/state/dash-venv/bin/python" -m pytest fabric_dash/tests/test_app.py -k "key_action" -q`
Expected: FAIL — no `k` binding / `action_key`.

- [ ] **Step 3: Implement in `app.py`**:

(a) Add the binding to the first BINDINGS list: `("k", "key", "Set key")`.

(b) Add the worker action (mirrors `action_effort`'s guard + modal + `_run_argv`):

```python
    @work
    async def action_key(self) -> None:
        if self._selected != "keys":
            self.query_one("#results", RichLog).write(
                "[yellow]open the Keys panel first, then press k[/]"
            )
            return
        providers = list(self.client.key_status().keys())
        if not providers:
            self.query_one("#results", RichLog).write("[yellow]no key providers to set[/]")
            return
        from .key_modal import KeySetModal
        choice = await self.push_screen_wait(KeySetModal(providers))
        if choice is None:
            return
        provider, secret = choice
        await self._run_argv(["key", "set", "--keychain", provider],
                             label=f"key set {provider}", stdin_input=secret)
```

(c) In `_actions_for`, surface the action on the Keys panel:

```python
        if node_id == "keys":
            items.append(FooterItem("k", "set key", SAFE, False))
```

- [ ] **Step 4: Add the help entry** — in `help.py` `_KEYS`, add `("k", "set API key (masked)")`. Keep the list accurate; ensure the P1 help test still passes.

- [ ] **Step 5: Run the full suite**

Run: `cd config/ai-litellm && "$HOME/.local/share/ai-litellm-fabric/state/dash-venv/bin/python" -m pytest fabric_dash/tests/ -q`
Expected: PASS — the 2 new tests + all prior. (`classify(["key","set","--keychain",…])` is SAFE → no ConfirmModal; the secret is piped via stdin, never in argv/log.)

- [ ] **Step 6: Commit**

```bash
git add config/ai-litellm/fabric_dash/app.py config/ai-litellm/fabric_dash/help.py config/ai-litellm/fabric_dash/tests/test_app.py
git commit -m "feat(dash): k -> set API key on Keys panel (masked, stdin, gated via _run_argv)"
```

---

## Self-Review

**Spec coverage (§14):** Task 1 = `stdin_input` on ActionRunner + `_run_argv` (secret never logged; 1-arg-spawn backward compat). Task 2 = `KeySetModal` (provider picker → masked `Input(password=True)`). Task 3 = `k`/`action_key` guarded to the Keys panel, runs `key set --keychain <provider>` with the secret via stdin, reuses `_run_argv` (SAFE → no ConfirmModal), action-bar + help. No backend change (stdin path pre-exists). The backend's "Run sync" line rides the output to the log (DRY). No P1/P2/P3 regression.

**Placeholder scan:** The `> Note:` blocks are concrete Textual-8.2.7 verification instructions with working in-repo references (palette.py/effort_modal.py) — same pattern P1/P2/P3 used. The security constraint is encoded in the tests (argv has no secret; secret only in stdin; secret never in a logged line).

**Type consistency:** `_default_spawn(argv, stdin_input=None)` ← `ActionRunner.run(argv, on_line, stdin_input=None)` ← `_run_argv(argv, label, consequence, stdin_input)` ← `action_key`. `KeySetModal(providers)` dismisses `(provider, secret) | None`, consumed by `action_key` → `_run_argv(["key","set","--keychain",provider], stdin_input=secret)`. The `key set --keychain <provider>` argv carries the provider name (resolved by the backend's `ai_litellm_key_name_to_env`), never the secret.

---

*Next: P4a (claude tier mapping editor) → P4b (codex facade mapping editor). See docs/superpowers/specs/2026-06-20-fabric-control-surface-v2-design.md §6.*
