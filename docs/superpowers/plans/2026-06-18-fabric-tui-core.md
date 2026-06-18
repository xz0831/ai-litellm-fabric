# fabric TUI Core — Implementation Plan (2 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the read-only `fabric` TUI: a Textual app with a concept tree, a live status header, and read panels that consume the `--json` surface, plus the packaging (`bin/fabric`, `ai-litellm dash`, install/check wiring). No mutating actions yet — those are Plan 3.

**Architecture:** A small Python package (`fabric_dash`) with three layers: (1) `client.py` shells out to `ai-litellm … --json` via an injectable runner and returns parsed dicts/lists; (2) `app.py` is the Textual `App` (header + `Tree` + content area + auto-refresh); (3) `__main__.py` is the entry point. `bin/fabric` is a thin shim → `ai-litellm dash` → `python3 -m fabric_dash`.

**Tech Stack:** Python 3, Textual (optional dependency), zsh shim/dispatch, pytest (Textual `Pilot` for headless UI tests).

**Depends on:** Plan 1 (`proxy status`, `model list`, `model limits`, `harness list/info`, `key status` already emit `--json`). This plan adds `--json` to `route list`, `runtime status`, `reasoning matrix`, `context matrix` (Task 1).

## Global Constraints

- backend logic unchanged; `--json` is output-formatter-only, additive, read-only, camelCase, empty-on-failure (`{}`/`[]`, exit 0). (spec §2, §4, §6, §9; Plan 1)
- no new runtime language; Textual is an **optional** dependency in the `litellm` mold — preflight notes if missing, `fabric` fails loudly with the install command if missing, never fatal at install. (spec §3, §8)
- Python package name is `fabric_dash` (NOT `dash` — avoids the PyPI `dash` clash); lives at `config/ai-litellm/fabric_dash/`. (resolves spec §8 path loosely naming `dash/`)
- the TUI never re-derives state and never runs mutating/billable commands in this plan. (spec §2, §5.1, §7)
- tests make **zero** real provider/network calls; the client runner is injected with canned JSON. (spec §10)

---

## File Structure

- Create: `config/ai-litellm/fabric_dash/__init__.py` — package marker + version.
- Create: `config/ai-litellm/fabric_dash/client.py` — `FabricClient` (subprocess → parsed JSON), injectable runner.
- Create: `config/ai-litellm/fabric_dash/app.py` — `FabricApp` (Textual App), `app.tcss`.
- Create: `config/ai-litellm/fabric_dash/app.tcss` — Textual CSS.
- Create: `config/ai-litellm/fabric_dash/__main__.py` — entry point.
- Create: `config/ai-litellm/fabric_dash/tests/test_client.py`, `tests/test_app.py`.
- Create: `bin/fabric` — shim.
- Modify: `config/ai-litellm/lib.zsh` — add `dash)` dispatch in `ai_litellm()` + usage line; add Task 1 `--json` emitters.
- Modify: `scripts/install.zsh` — install the `fabric_dash` package dir + `bin/fabric`.
- Modify: `scripts/check.zsh` — assert `fabric` shim, `python3 -m fabric_dash --help`, the new `--json` commands.
- Modify: `README.md` — `fabric` usage.

---

## Task 1: Remaining read `--json` (route list, runtime status, reasoning matrix, context matrix)

**Files:**
- Modify: `config/ai-litellm/lib.zsh` (`ai_litellm_route_info` 2153; `ai_litellm_runtime_status` 1731; `ai_litellm_reasoning_matrix`; `ai_litellm_context_matrix` 4235; sub-dispatchers `ai_litellm_cmd_route`, `ai_litellm_cmd_runtime`, `ai_litellm_cmd_reasoning`, `ai_litellm_cmd_context`)
- Test: `scripts/check.zsh`

**Interfaces:**
- Consumes: Plan 1's `ai_litellm_emit_json`; existing `route info`/`runtime status`/matrix derivations.
- Produces: `ai_litellm_route_list_json` → `[{modelName, providerModel, provider}]`; `ai_litellm_runtime_status_json [name]` → `[{name, baseUrl, apiBase, health, requiredModels:[{model,ok}], advertisedModels:[…]}]`; `ai_litellm_reasoning_matrix_json [model]` → `[{model, effort, dropRisk}]`; `ai_litellm_context_matrix_json [filter]` → `[{surface, model, declared, configured, effectiveInput, enforcement}]`.

- [ ] **Step 1: Write the failing test** — append to `scripts/check.zsh` (reuses Plan 1's `json_check`):

```zsh
for cmd in "route list" "runtime status" "reasoning matrix" "context matrix"; do
  json_check "$cmd --json" ai-litellm ${=cmd} --json
done
echo "ok: route/runtime/reasoning/context --json"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/check.zsh`
Expected: FAIL — these commands print text, so `json_check` reports invalid JSON.

- [ ] **Step 3: Add the four JSON emitters** — in `config/ai-litellm/lib.zsh`, each next to its text sibling. Follow Plan 1's rule: reuse the existing derivation, serialize with Ruby `JSON.generate` or `ai_litellm_emit_json`, fall back to `[]`. Route list (uses live `/model/info`, like `ai_litellm_route_info`):

```zsh
ai_litellm_route_list_json() {
  command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { printf '[]'; return 0; }
  curl -fsS -m 5 $(ai_litellm_curl_auth) "$(ai_litellm_base_url)/model/info" 2>/dev/null \
    | jq -c '[.data[]? | {modelName: .model_name, providerModel: (.litellm_params.model // .model_name), provider: (.litellm_params.custom_llm_provider // "")}]' 2>/dev/null \
    || printf '[]'
}
```

Runtime status, reasoning matrix, context matrix: add `*_json` siblings that call the SAME helpers the text formatters call and emit via Ruby `JSON.generate` (the matrix formatters already build row structures in Ruby — add a `--format=json` branch or a parallel `print JSON.generate(rows)` path). Verify each against its text command in Step 5.

> Note: `ai_litellm_context_matrix` (line 4235) is a ~460-line embedded Ruby program that already builds `rows`. The cheapest correct change is to teach that Ruby block to accept an env flag `AI_LITELLM_MATRIX_JSON=1` and `print JSON.generate(rows)` instead of the `printf` table when set; then `ai_litellm_context_matrix_json` is `AI_LITELLM_MATRIX_JSON=1 ai_litellm_context_matrix "$@"`. Same approach for `reasoning matrix`. This avoids duplicating the scoring logic.

- [ ] **Step 4: Wire `--json` into the four sub-dispatchers** — in each of `ai_litellm_cmd_route`, `ai_litellm_cmd_runtime`, `ai_litellm_cmd_reasoning`, `ai_litellm_cmd_context`, gate the default/list/status/matrix verb on a trailing `--json` (same pattern as Plan 1 Tasks 1–3). Example for route:

```zsh
    list|"")
      if [[ "${1:-}" == "--json" ]]; then ai_litellm_route_list_json; else ai_litellm_route_list; fi
      ;;
```

- [ ] **Step 5: Run the test + value spot-check**

Run: `./scripts/check.zsh` → Expected: PASS (`ok: route/runtime/reasoning/context --json`).
Run each `--json` vs its text command; confirm row counts/values agree. Adjust the Ruby json branch to match the text numbers if they differ.

- [ ] **Step 6: Commit**

```bash
git add config/ai-litellm/lib.zsh scripts/check.zsh
git commit -m "feat(cli): add route/runtime/reasoning/context --json"
```

---

## Task 2: Python package skeleton + `client.py`

**Files:**
- Create: `config/ai-litellm/fabric_dash/__init__.py`, `client.py`, `tests/test_client.py`

**Interfaces:**
- Produces: `FabricClient(runner=None)` with methods returning parsed JSON: `proxy_status() -> dict`, `model_list() -> list`, `model_limits(model=None) -> list`, `route_list() -> list`, `runtime_status() -> list`, `reasoning_matrix() -> list`, `context_matrix() -> list`, `harness_list() -> list`, `key_status() -> dict`. The `runner` is `Callable[[list[str]], tuple[int, str]]` (argv → (returncode, stdout)); default shells out to `ai-litellm`. On nonzero exit or invalid JSON, object methods return `{}` and list methods return `[]` (never raise).

- [ ] **Step 1: Write the failing test** — `config/ai-litellm/fabric_dash/tests/test_client.py`:

```python
import json
from fabric_dash.client import FabricClient

def fake(out_by_cmd):
    def run(argv):
        key = " ".join(argv)
        if key in out_by_cmd:
            return (0, out_by_cmd[key])
        return (1, "")
    return run

def test_proxy_status_parses():
    c = FabricClient(runner=fake({
        "ai-litellm proxy status --json": json.dumps({"health": "ok", "configCurrency": "stale"})
    }))
    s = c.proxy_status()
    assert s["health"] == "ok"
    assert s["configCurrency"] == "stale"

def test_list_method_empty_on_failure():
    c = FabricClient(runner=fake({}))  # every cmd returns rc=1
    assert c.model_list() == []

def test_object_method_empty_on_invalid_json():
    c = FabricClient(runner=fake({"ai-litellm proxy status --json": "not json"}))
    assert c.proxy_status() == {}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd config/ai-litellm && python3 -m pytest fabric_dash/tests/test_client.py -q`
Expected: FAIL — `fabric_dash.client` does not exist (ImportError).

- [ ] **Step 3: Create the package + client** — `config/ai-litellm/fabric_dash/__init__.py`:

```python
__version__ = "0.1.0"
```

`config/ai-litellm/fabric_dash/client.py`:

```python
"""Read-only client over the `ai-litellm … --json` surface.

Never re-derives state; never runs mutating/billable commands. On any failure
returns an empty container so the TUI shows "empty", never a traceback.
"""
from __future__ import annotations
import json
import subprocess
from typing import Callable, Optional

Runner = Callable[[list], tuple]


def _default_runner(argv: list) -> tuple:
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=15)
        return (p.returncode, p.stdout)
    except Exception:
        return (1, "")


class FabricClient:
    def __init__(self, runner: Optional[Runner] = None, binary: str = "ai-litellm"):
        self._run = runner or _default_runner
        self._bin = binary

    def _json(self, *args: str):
        rc, out = self._run([self._bin, *args])
        if rc != 0:
            return None
        try:
            return json.loads(out)
        except Exception:
            return None

    def _obj(self, *args: str) -> dict:
        v = self._json(*args)
        return v if isinstance(v, dict) else {}

    def _arr(self, *args: str) -> list:
        v = self._json(*args)
        return v if isinstance(v, list) else []

    def proxy_status(self) -> dict: return self._obj("proxy", "status", "--json")
    def key_status(self) -> dict: return self._obj("key", "status", "--json")
    def model_list(self) -> list: return self._arr("model", "list", "--json")
    def model_limits(self, model: Optional[str] = None) -> list:
        return self._arr("model", "limits", model, "--json") if model else self._arr("model", "limits", "--json")
    def route_list(self) -> list: return self._arr("route", "list", "--json")
    def runtime_status(self) -> list: return self._arr("runtime", "status", "--json")
    def reasoning_matrix(self) -> list: return self._arr("reasoning", "matrix", "--json")
    def context_matrix(self) -> list: return self._arr("context", "matrix", "--json")
    def harness_list(self) -> list: return self._arr("harness", "list", "--json")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd config/ai-litellm && python3 -m pytest fabric_dash/tests/test_client.py -q`
Expected: PASS (3 passed).

- [ ] **Step 5: Commit**

```bash
git add config/ai-litellm/fabric_dash/__init__.py config/ai-litellm/fabric_dash/client.py config/ai-litellm/fabric_dash/tests/test_client.py
git commit -m "feat(dash): add read-only FabricClient over --json surface"
```

---

## Task 3: Textual app shell — header + concept tree + content area

**Files:**
- Create: `config/ai-litellm/fabric_dash/app.py`, `app.tcss`, `__main__.py`, `tests/test_app.py`

**Interfaces:**
- Consumes: `FabricClient` (Task 2).
- Produces: `FabricApp(client=None)` — Textual `App`; tree node ids `proxy|harnesses|models|runtimes|budget|keys`; content widget `#content`; status bar `#status`. `__main__` runs `FabricApp().run()`; `--help` prints usage and exits 0 without importing Textual heavy paths failing.

- [ ] **Step 1: Write the failing test** — `config/ai-litellm/fabric_dash/tests/test_app.py`:

```python
import json
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
async def test_app_boots_and_shows_proxy_health():
    app = FabricApp(client=make_client())
    async with app.run_test() as pilot:
        await pilot.pause()
        status = app.query_one("#status").renderable if hasattr(app.query_one("#status"), "renderable") else str(app.query_one("#status").render())
        assert "ok" in str(status)
        # concept tree has the six top nodes
        from textual.widgets import Tree
        tree = app.query_one(Tree)
        labels = [str(n.label) for n in tree.root.children]
        assert any("Proxy" in l for l in labels)
        assert any("Models" in l for l in labels)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd config/ai-litellm && python3 -m pytest fabric_dash/tests/test_app.py -q`
Expected: FAIL — `fabric_dash.app` does not exist. (If Textual/pytest-asyncio not installed: `python3 -m pip install textual pytest pytest-asyncio` first.)

- [ ] **Step 3: Create `app.tcss`** — `config/ai-litellm/fabric_dash/app.tcss`:

```css
#status { dock: top; height: 1; background: $panel; color: $text; padding: 0 1; }
#body { height: 1fr; }
Tree { width: 28; border-right: solid $primary; }
#content { width: 1fr; padding: 0 1; }
.ok { color: $success; }
.warn { color: $warning; }
.bad { color: $error; }
```

- [ ] **Step 4: Create `app.py`** — `config/ai-litellm/fabric_dash/app.py`:

```python
"""fabric — read-only control-plane TUI over ai-litellm."""
from __future__ import annotations
from pathlib import Path
from textual.app import App, ComposeResult
from textual.containers import Horizontal
from textual.widgets import Header, Footer, Tree, Static, DataTable
from .client import FabricClient

CONCEPTS = [
    ("proxy", "Proxy"),
    ("harnesses", "Harnesses"),
    ("models", "Models / Routes"),
    ("runtimes", "Runtimes"),
    ("budget", "Budget & Policy"),
    ("keys", "Keys"),
]


class FabricApp(App):
    CSS_PATH = "app.tcss"
    TITLE = "ai-litellm fabric"
    BINDINGS = [("q", "quit", "Quit"), ("r", "refresh", "Refresh")]

    def __init__(self, client: FabricClient | None = None):
        super().__init__()
        self.client = client or FabricClient()
        self._selected = "proxy"

    def compose(self) -> ComposeResult:
        yield Header()
        yield Static("", id="status")
        with Horizontal(id="body"):
            tree: Tree = Tree("Concepts", id="concepts")
            tree.show_root = False
            for node_id, label in CONCEPTS:
                tree.root.add_leaf(label, data=node_id)
            yield tree
            yield Static("", id="content")
        yield Footer()

    def on_mount(self) -> None:
        self.refresh_status()
        self.show_panel("proxy")
        self.set_interval(4.0, self.refresh_status)  # safe/read-only auto-refresh only

    def on_tree_node_selected(self, event: Tree.NodeSelected) -> None:
        node_id = event.node.data
        if node_id:
            self._selected = node_id
            self.show_panel(node_id)

    def action_refresh(self) -> None:
        self.refresh_status()
        self.show_panel(self._selected)

    def refresh_status(self) -> None:
        s = self.client.proxy_status()
        health = s.get("health", "unknown")
        cur = s.get("configCurrency", "unknown")
        url = s.get("baseUrl", "")
        dot = {"ok": "[green]●[/]", "unreachable": "[red]●[/]"}.get(health, "[yellow]●[/]")
        badge = "[yellow]STALE → sync[/]" if cur == "stale" else f"[dim]{cur}[/]"
        self.query_one("#status", Static).update(f"{dot} proxy: {health}   config: {badge}   {url}")

    def show_panel(self, node_id: str) -> None:
        content = self.query_one("#content", Static)
        if node_id == "proxy":
            s = self.client.proxy_status()
            lines = [f"{k}: {v}" for k, v in s.items()] or ["proxy not running — start it"]
            content.update("\n".join(lines))
        elif node_id == "models":
            rows = self.client.model_limits() or self.client.model_list()
            content.update(_table_text(rows))
        elif node_id == "harnesses":
            content.update(_table_text(self.client.harness_list()))
        elif node_id == "runtimes":
            content.update(_table_text(self.client.runtime_status()) or "no runtimes")
        elif node_id == "budget":
            content.update(_table_text(self.client.reasoning_matrix()) or "no reasoning matrix")
        elif node_id == "keys":
            k = self.client.key_status()
            content.update("\n".join(f"{name}: {info.get('source','?')}" for name, info in k.items()) or "no keys")
        else:
            content.update("")


def _table_text(rows: list) -> str:
    if not rows:
        return ""
    cols = list(rows[0].keys())
    head = "  ".join(f"{c:<18}" for c in cols)
    body = "\n".join("  ".join(f"{str(r.get(c,'')):<18}" for c in cols) for r in rows)
    return head + "\n" + body
```

> Note: `_table_text` is a deliberate v2-core simplification (monospace columns in a `Static`). Plan 3 / a later polish task can swap panels to real `DataTable`/`RichLog` widgets; the read-only contract and tree wiring stay the same.

- [ ] **Step 5: Create `__main__.py`** — `config/ai-litellm/fabric_dash/__main__.py`:

```python
import sys

USAGE = "fabric — ai-litellm control-plane TUI\n\nUsage: fabric            launch the dashboard\n       fabric --help     show this help\n"


def main() -> int:
    if "--help" in sys.argv[1:] or "-h" in sys.argv[1:]:
        print(USAGE)
        return 0
    try:
        from .app import FabricApp
    except ModuleNotFoundError as e:
        if "textual" in str(e):
            print("fabric requires Textual: python3 -m pip install textual", file=sys.stderr)
            return 1
        raise
    FabricApp().run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd config/ai-litellm && python3 -m pytest fabric_dash/tests/ -q`
Expected: PASS (all client + app tests). Also: `python3 -m fabric_dash --help` prints usage, exit 0.

- [ ] **Step 7: Commit**

```bash
git add config/ai-litellm/fabric_dash/
git commit -m "feat(dash): Textual app shell with concept tree + read panels"
```

---

## Task 4: `bin/fabric` shim + `ai-litellm dash` dispatch

**Files:**
- Create: `bin/fabric`
- Modify: `config/ai-litellm/lib.zsh` (`ai_litellm()` dispatcher + `ai_litellm_usage`)

**Interfaces:**
- Consumes: installed `fabric_dash` package under `$AI_LITELLM_CONFIG_HOME/ai-litellm/fabric_dash`.
- Produces: `ai-litellm dash [args]` runs the TUI; `fabric [args]` shim → `ai-litellm dash`.

- [ ] **Step 1: Create `bin/fabric`** — mirror the existing shim bootstrap (see `bin/goose-litellm`), ending in:

```zsh
#!/usr/bin/env zsh
# Resolve fabric package home (env → checkout-relative → default), load nvm if present.
AI_LITELLM_FABRIC_HOME="${AI_LITELLM_FABRIC_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/ai-litellm-fabric}"
exec "$AI_LITELLM_FABRIC_HOME/bin/ai-litellm" dash "$@"
```

> Note: match the exact bootstrap (nvm sourcing, `${0:A:h}` checkout-relative fallback) used by `bin/goose-litellm` so `fabric` works both from a checkout and when installed. Read `bin/goose-litellm` and copy its header verbatim, changing only the final `exec` line.

- [ ] **Step 2: Add `dash)` dispatch** — in `ai_litellm()` (around the `uninstall)`/`capabilities)` cases, ~line 5796):

```zsh
    dash)
      shift
      PYTHONPATH="$AI_LITELLM_CONFIG_HOME/ai-litellm${PYTHONPATH:+:$PYTHONPATH}" \
        command python3 -m fabric_dash "$@"
      ;;
```

- [ ] **Step 3: Add usage line** — in `ai_litellm_usage()` add under the command list:

```
  Dash:     ai-litellm dash          Launch the fabric control-plane TUI (or run: fabric)
```

- [ ] **Step 4: Manual smoke (no automated UI launch in CI)**

Run from the checkout: `AI_LITELLM_CONFIG_HOME="$PWD/config" ./bin/ai-litellm dash --help`
Expected: prints the fabric usage, exit 0 (proves dispatch + module resolution without launching the full UI).

- [ ] **Step 5: Commit**

```bash
git add bin/fabric config/ai-litellm/lib.zsh
git commit -m "feat(dash): add fabric shim and ai-litellm dash dispatch"
```

---

## Task 5: Install / check / README wiring

**Files:**
- Modify: `scripts/install.zsh`, `scripts/check.zsh`, `README.md`

**Interfaces:**
- Consumes: install renders package files to `$prefix`.
- Produces: installed `bin/fabric` shim + `$prefix/config/ai-litellm/fabric_dash/*`; preflight notes Textual; check asserts the shim + module + `--json`.

- [ ] **Step 1: Install the package dir + shim** — in `scripts/install.zsh`:
  1. Add `fabric_dash` `.py` files to install. After the harness-descriptor loop (~line 358), add:

```zsh
for pyfile in "$repo_root"/config/ai-litellm/fabric_dash/**/*.py(N); do
  rel="${pyfile#$repo_root/config/ai-litellm/}"
  install_rendered "$pyfile" "$prefix/config/ai-litellm/$rel"
done
install_rendered "$repo_root/config/ai-litellm/fabric_dash/app.tcss" "$prefix/config/ai-litellm/fabric_dash/app.tcss"
```

  2. Add `fabric` to the shim+executable loop (line 309 require list and 369 install loop): append `fabric` to both `for script in … ` lists.
  3. In `preflight()` after the litellm note (~line 99), add a Textual note:

```zsh
command -v python3 >/dev/null 2>&1 && python3 -c 'import textual' >/dev/null 2>&1 || \
  echo "note: Textual not found — needed for the 'fabric' dashboard (python3 -m pip install textual); install proceeds without it." >&2
```

> Note: `fabric_dash/tests/` should NOT be installed to `$prefix`. Exclude tests in the glob (`fabric_dash/*.py` for top level) or add a guard `[[ "$rel" == */tests/* ]] && continue` inside the loop.

- [ ] **Step 2: Add check assertions** — in `scripts/check.zsh`, within the real-install-to-mktemp section, after shims are verified add:

```zsh
[[ -x "$tmp_bin/fabric" ]] || { echo "FAIL: fabric shim missing"; exit 1; }
PYTHONPATH="$tmp_prefix/config/ai-litellm" python3 -m fabric_dash --help >/dev/null 2>&1 \
  || { echo "FAIL: fabric_dash module not importable / --help failed"; exit 1; }
echo "ok: fabric shim + module"
```

> Note: use the same temp prefix/bin variable names the surrounding check.zsh install block already defines; read that block and match its variable names (it installs into an `mktemp` HOME).

- [ ] **Step 3: Run the full check**

Run: `./scripts/check.zsh`
Expected: PASS including `ok: fabric shim + module` and all `--json` lines.

- [ ] **Step 4: README** — add a `## Dashboard` section:

```markdown
## Dashboard

`fabric` is a read-only control-plane TUI over the `ai-litellm` commands:

​```zsh
fabric            # or: ai-litellm dash
​```

It shows proxy health, config currency, models/routes, runtimes, budget
policy, and keys in one screen. Requires Textual (`python3 -m pip install
textual`); the rest of the package works without it.
```

- [ ] **Step 5: Commit**

```bash
git add scripts/install.zsh scripts/check.zsh README.md
git commit -m "feat(dash): install/check/readme wiring for fabric TUI"
```

---

## Self-Review

**Spec coverage:** Read panels (Proxy/Harnesses/Models·Routes/Runtimes/Budget/Keys, spec §5), live status header + 4s safe auto-refresh (§5.1), `--json`-only data access (§4), Textual-as-optional-dep (§3, §8), `fabric`→`ai-litellm dash` packaging (§8), zero-network tests (§10). Deferred to Plan 3: action bar, confirm modals, launch flow, doctor runner, safety classification UI (§6, §7 actions).

**Placeholder scan:** `> Note:` blocks point to verbatim-copy/verify-against-existing-code with concrete fallbacks (shim header from `bin/goose-litellm`, check var names, matrix JSON via env flag) — not unspecified work. All code steps are runnable.

**Type consistency:** `FabricClient` method names (`proxy_status`, `model_limits`, `route_list`, `runtime_status`, `reasoning_matrix`, `context_matrix`, `harness_list`, `key_status`) match between `client.py`, tests, and `app.py`. Tree node ids (`proxy|harnesses|models|runtimes|budget|keys`) match `CONCEPTS` and `show_panel`. JSON keys match Plan 1/Task 1 emitters (`health`, `configCurrency`, `baseUrl`).

---

*Next: Plan 3 — TUI actions + safety (action bar, safety classification, confirm modals for restart/billable ops, harness launch flow, doctor-all runner, Pilot tests for the confirm gate).*
