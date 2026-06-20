# fabric v2 — P4a: Claude Tier Mapping Editor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remap a Claude tier (fable/opus/sonnet/haiku) to a different model from the `fabric` TUI: on the Harnesses panel select claude, press `m`, pick a tier, pick a model — and the backend rewrites the tier's proxy alias, direct alias, and display labels consistently in `claude-litellm/settings.json`.

**Architecture:** A new backend `harness alias get/set <harness> …` command owns the logic (validate the model exists, derive the direct alias + labels from the chosen model's litellm config, preserve the intentional proxy/direct split for local models, atomic write). The TUI is a thin caller: a `TierMapModal` (tier picker → model picker) returns `(tier, model)`, and the app runs `harness alias set claude <tier> <model>` through the existing gated `_run_argv` (`alias set` classifies SAFE → immediate). Generic over harness so P4b reuses it for codex.

**Tech Stack:** zsh (lib.zsh polyglot), Python 3 + Textual 8.2.7, pytest + Pilot, package venv; `check.zsh` for backend assertions.

## Global Constraints

- ALL dash python under the venv: `cd config/ai-litellm && "$HOME/.local/share/ai-litellm-fabric/state/dash-venv/bin/python" -m pytest fabric_dash/tests/ -q`. Backend gate: `AI_LITELLM_SKIP_DASH_VENV=1 zsh scripts/check.zsh`. Branch `feat/fabric-v2-p4a-claude-mapping`; do NOT switch branches. (spec §3)
- **backend owns logic, TUI is a caller** — the TUI never edits settings.json; it calls `ai-litellm harness alias …`. The new `alias get --json` is READ-ONLY additive (returns `[]` on failure). (spec §3, §15)
- **A tier maps to FOUR keys** in `config/claude-litellm/settings.json` (resolved via `ai_litellm_harness_json claude paths.settings`): `aliases.<tier>` (proxy litellm model_name), `directAliases.<tier>` (direct provider model), `displayNames.<tier>` + `directDisplayNames.<tier>` (labels). `alias set` writes them consistently and atomically, preserving all other keys. (spec §15, settings.json fact)
- **Derivation:** for a CLOUD target (the model's `litellm_params.model` starts with `openrouter/`), `directAlias = litellm_params.model` minus the `openrouter/` prefix; labels = `"<model_name without trailing -<provider>> (<provider>)"`. For a LOCAL target (`litellm_params.model` starts with `openai/local`), leave `directAliases`/`directDisplayNames` UNCHANGED and warn — direct mode has no local lane (the intentional split; see [[project-model-remap-glm52]]). Always set the proxy `aliases`/`displayNames`. (spec §15)
- **Single risk oracle / gate reuse** — execution flows through the existing `_run_argv` (gate via `safety.classify`); `harness alias set …` classifies SAFE → immediate, no new ConfirmModal. (spec §12, §15)
- **No tier add/remove** — only remap the 4 existing tiers (from `ai_litellm_harness_json claude models.tiers`). codex facades = P4b. No secrets. (spec §15)
- No P1/P2/P3/P3b regression. Tests make ZERO real subprocess/network calls. Validate Textual 8.2.7 APIs and adapt. (spec §3, §10)

---

## File Structure

- Modify: `config/ai-litellm/lib.zsh` — `ai_litellm_harness_alias_json` (read) + `ai_litellm_harness_alias_set` (write+derive) + the `harness)` `alias)` dispatch arm.
- Modify: `scripts/check.zsh` — assertions for the read + a set round-trip.
- Modify: `config/ai-litellm/fabric_dash/client.py` — `harness_aliases(name)` read method.
- Create: `config/ai-litellm/fabric_dash/tier_modal.py` — `TierMapModal` (tier picker → model picker).
- Modify: `config/ai-litellm/fabric_dash/app.py` — `m` binding + `action_map`; `_actions_for` adds `[m] mapping` on the Harnesses panel.
- Modify: `config/ai-litellm/fabric_dash/help.py` — `m` keymap entry.
- Test: `tests/test_client.py`, `tests/test_app.py` (additions).

---

## Task 1: Backend `harness alias get --json` + `harness alias set`

**Files:**
- Modify: `config/ai-litellm/lib.zsh` (add the two functions; add an `alias)` arm to the `harness)` subcommand dispatch — the same block that routes `reasoning)`/`list)`/`info)`/`launch)`)
- Modify: `scripts/check.zsh`

**Interfaces:**
- Produces (CLI): `ai-litellm harness alias get <harness> --json` → `[{"tier","model","direct","label"}, …]` (one per tier, current mapping); `ai-litellm harness alias set <harness> <tier> <model_name>` → writes aliases/directAliases/displayNames/directDisplayNames consistently to the harness's settings.json, prints a confirmation + "Run 'ai-litellm sync' …".

- [ ] **Step 1: Add the read function** — in `lib.zsh`, near the other harness functions. It reads the harness's settings + the tiers list and emits the current mapping as JSON (match the file's existing `--json` idiom; reuse `ai_litellm_ruby`):

```zsh
ai_litellm_harness_alias_json() {
  local harness="${1:-claude}"
  local settings
  settings="$(ai_litellm_harness_json "$harness" paths.settings 2>/dev/null)" || { printf '[]'; return 0; }
  [[ -f "$settings" ]] || { printf '[]'; return 0; }
  local tiers
  tiers="$(ai_litellm_harness_json_array "$harness" models.tiers 2>/dev/null)"
  ai_litellm_ruby -rjson -e '
    settings = JSON.parse(File.read(ARGV[0])) rescue {}
    tiers = ARGV[1].to_s.split("\n").reject(&:empty?)
    al = settings["aliases"] || {}; dal = settings["directAliases"] || {}
    dn = settings["displayNames"] || {}; out = []
    tiers.each do |t|
      out << {"tier" => t, "model" => al[t], "direct" => dal[t], "label" => dn[t]}
    end
    puts JSON.generate(out)
  ' "$settings" "$tiers" 2>/dev/null || printf '[]'
}
```

- [ ] **Step 2: Add the write function (validate + derive + atomic)** — `alias set`. It validates the model exists in the litellm `model_list`, derives the direct alias + labels, and writes the four keys atomically, preserving the rest of settings.json:

```zsh
ai_litellm_harness_alias_set() {
  local harness="${1:-}" tier="${2:-}" model="${3:-}"
  if [[ -z "$harness" || -z "$tier" || -z "$model" ]]; then
    echo "Usage: ai-litellm harness alias set <harness> <tier> <model_name>" >&2
    return 1
  fi
  local settings
  settings="$(ai_litellm_harness_json "$harness" paths.settings 2>/dev/null)" || { echo "No settings for harness: $harness" >&2; return 1; }
  ai_litellm_ruby -rjson -e '
    config_path, settings_path, tier, model = ARGV
    settings = JSON.parse(File.read(settings_path))
    cfg = (YAML.load_file(config_path, aliases: true) rescue YAML.load_file(config_path)) rescue {"model_list"=>[]}
    entry = Array(cfg["model_list"]).find { |e| e["model_name"].to_s == model }
    abort("Unknown LiteLLM model_name: #{model}") unless entry
    backend = entry.dig("litellm_params", "model").to_s   # e.g. openrouter/deepseek/deepseek-v4-pro
    provider = backend.split("/", 2).first
    # proxy side (always)
    (settings["aliases"] ||= {})[tier] = model
    name = model.sub(/-#{Regexp.escape(provider)}$/, "")  # "GLM-5.2-openrouter" -> "GLM-5.2"
    (settings["displayNames"] ||= {})[tier] = "#{name} (#{provider})"
    # direct side: cloud -> derive; local -> leave unchanged + warn
    if provider == "openrouter"
      (settings["directAliases"] ||= {})[tier] = backend.sub(%r{\Aopenrouter/}, "")
      (settings["directDisplayNames"] ||= {})[tier] = "#{name} (#{provider})"
      STDERR.puts "warn: direct alias updated to #{settings["directAliases"][tier]}"
    else
      STDERR.puts "warn: #{model} is a local/#{provider} model — direct alias left unchanged (no direct lane)."
    end
    tmp = "#{settings_path}.tmp.#{$$}"
    File.write(tmp, JSON.pretty_generate(settings) + "\n")
    File.rename(tmp, settings_path)
  ' "$AI_LITELLM_CONFIG" "$settings" "$tier" "$model" || return $?
  echo "Set $harness $tier -> $model"
  echo "Run 'ai-litellm sync' to apply it to the running proxy."
}
```

> Note: confirm `$AI_LITELLM_CONFIG` is the litellm_config.yaml path (it is — used by the model-reasoning functions). `ai_litellm_ruby` needs `-ryaml` too for `YAML.load_file`; add `-ryaml` to the `-rjson` invocation. Verify `ai_litellm_harness_json_array` exists (used by the reservation check at lib.zsh ~5582) for the tiers list.

- [ ] **Step 3: Wire the dispatch** — in the `harness)` subcommand `case` (the block with `reasoning)`/`list)`/`info)`/`launch)`), add:

```zsh
    alias)
      case "${1:-}" in
        set) shift; ai_litellm_harness_alias_set "$@" ;;
        *)   if [[ "${2:-}" == "--json" || "${1:-}" == "--json" ]]; then ai_litellm_harness_alias_json "${1:-claude}"
             else ai_litellm_harness_alias_json "${1:-claude}"; fi ;;
      esac
      ;;
```

(Update the harness `Usage:` line to mention `alias get <harness>|alias set <harness> <tier> <model>`.)

- [ ] **Step 4: Add check.zsh assertions** — near the existing `--json` assertions: read returns the 4 tiers; a set round-trip changes the alias then restores it (so the test leaves settings.json unchanged):

```zsh
a_json="$(ai-litellm harness alias get claude --json 2>/dev/null)"
echo "$a_json" | jq -e 'type=="array" and length==4 and (.[0]|has("tier") and has("model"))' >/dev/null \
  || { echo "FAIL: harness alias get --json"; exit 1; }
orig="$(ai-litellm harness alias get claude --json | jq -r '.[]|select(.tier=="fable").model')"
ai-litellm harness alias set claude fable DeepSeek-V4-Pro-openrouter >/dev/null 2>&1
now="$(ai-litellm harness alias get claude --json | jq -r '.[]|select(.tier=="fable").model')"
ai-litellm harness alias set claude fable "$orig" >/dev/null 2>&1   # restore
[[ "$now" == "DeepSeek-V4-Pro-openrouter" && "$orig" != "$now" ]] \
  || { echo "FAIL: harness alias set round-trip"; exit 1; }
echo "ok: harness alias get/set (claude tiers)"
```

> Note: use model_names that exist in the live config (`DeepSeek-V4-Pro-openrouter` is opus's; verify with `ai-litellm model list`). The test restores the original so the repo's settings.json is unchanged.

- [ ] **Step 5: Run the backend gate**

Run: `AI_LITELLM_SKIP_DASH_VENV=1 zsh scripts/check.zsh`
Expected: exit 0, including the new "harness alias get/set" line. Also confirm by hand: `source config/ai-litellm/lib.zsh` then `ai-litellm harness alias get claude --json | jq .` shows 4 tiers; a set+restore leaves `git diff config/claude-litellm/settings.json` empty.

- [ ] **Step 6: Commit**

```bash
git add config/ai-litellm/lib.zsh scripts/check.zsh
git commit -m "feat(cli): harness alias get --json / set <harness> <tier> <model> (claude tiers)"
```

---

## Task 2: FabricClient alias read

**Files:**
- Modify: `config/ai-litellm/fabric_dash/client.py`
- Test: `config/ai-litellm/fabric_dash/tests/test_client.py`

**Interfaces:**
- Consumes: the Task 1 CLI read.
- Produces: `FabricClient.harness_aliases(name: str) -> list` — `[{"tier","model","direct","label"}, …]`, `[]` on failure (reuses `_arr`).

- [ ] **Step 1: Write the failing test** — append to `tests/test_client.py`:

```python
def test_harness_aliases_read():
    from fabric_dash.client import FabricClient
    seen = []
    def run(argv):
        seen.append(argv)
        if argv[:4] == ["ai-litellm", "harness", "alias", "get"]:
            return (0, '[{"tier":"fable","model":"GLM-5.2-openrouter","direct":"z-ai/glm-5.2","label":"GLM-5.2 (openrouter)"}]')
        return (1, "")
    c = FabricClient(runner=run)
    rows = c.harness_aliases("claude")
    assert rows[0]["tier"] == "fable" and rows[0]["model"] == "GLM-5.2-openrouter"
    assert ["ai-litellm", "harness", "alias", "get", "claude", "--json"] in seen
    assert FabricClient(runner=lambda a: (1, "")).harness_aliases("claude") == []
```

- [ ] **Step 2: Run to verify failure**

Run: `cd config/ai-litellm && "$HOME/.local/share/ai-litellm-fabric/state/dash-venv/bin/python" -m pytest fabric_dash/tests/test_client.py::test_harness_aliases_read -q`
Expected: FAIL — method doesn't exist.

- [ ] **Step 3: Implement** — in `client.py`, add (mirroring the existing `_arr` readers):

```python
    def harness_aliases(self, name: str) -> list:
        return self._arr("harness", "alias", "get", name, "--json")
```

- [ ] **Step 4: Run to verify pass**

Run: `cd config/ai-litellm && "$HOME/.local/share/ai-litellm-fabric/state/dash-venv/bin/python" -m pytest fabric_dash/tests/ -q`
Expected: PASS (all).

- [ ] **Step 5: Commit**

```bash
git add config/ai-litellm/fabric_dash/client.py config/ai-litellm/fabric_dash/tests/test_client.py
git commit -m "feat(dash): FabricClient.harness_aliases read"
```

---

## Task 3: `TierMapModal` (tier picker → model picker)

**Files:**
- Create: `config/ai-litellm/fabric_dash/tier_modal.py`
- Modify: `config/ai-litellm/fabric_dash/app.tcss`
- Test: `config/ai-litellm/fabric_dash/tests/test_app.py`

**Interfaces:**
- Produces: `TierMapModal(ModalScreen)` — `__init__(self, tiers: list[dict], models: list[str])`. Two modes: tier-pick (a `ListView` of `"<tier> -> <current model>"`) → model-pick (a `ListView` of `models`). Dismisses with `(tier: str, model: str)` on the model pick, or `None` (escape).

- [ ] **Step 1: Write the failing tests** — append to `tests/test_app.py`:

```python
@pytest.mark.asyncio
async def test_tier_modal_pick_tier_then_model_returns_tuple():
    from fabric_dash.tier_modal import TierMapModal
    captured = {}
    tiers = [{"tier": "fable", "model": "GLM-5.2-openrouter"}, {"tier": "opus", "model": "DeepSeek-V4-Pro-openrouter"}]
    models = ["GLM-5.2-openrouter", "Kimi-K2.6-openrouter"]
    app = FabricApp(client=make_client())
    async with app.run_test() as pilot:
        await pilot.pause()
        async def grab():
            captured["c"] = await app.push_screen_wait(TierMapModal(tiers, models))
        app.run_worker(grab())
        await pilot.pause()
        await pilot.press("down")          # tier -> opus (index 1)
        await pilot.press("enter")         # enter model-pick mode
        await pilot.pause()
        await pilot.press("down")          # model -> Kimi (index 1)
        await pilot.press("enter")
        await pilot.pause()
        tier, model = captured["c"]
        assert tier == "opus" and model == "Kimi-K2.6-openrouter"

@pytest.mark.asyncio
async def test_tier_modal_escape_cancels():
    from fabric_dash.tier_modal import TierMapModal
    captured = {}
    app = FabricApp(client=make_client())
    async with app.run_test() as pilot:
        await pilot.pause()
        async def grab():
            captured["c"] = await app.push_screen_wait(TierMapModal([{"tier": "fable", "model": "x"}], ["x"]))
        app.run_worker(grab())
        await pilot.pause()
        await pilot.press("escape"); await pilot.pause()
        assert captured["c"] is None
```

- [ ] **Step 2: Run to verify failure**

Run: `cd config/ai-litellm && "$HOME/.local/share/ai-litellm-fabric/state/dash-venv/bin/python" -m pytest fabric_dash/tests/test_app.py -k tier_modal -q`
Expected: FAIL — `fabric_dash.tier_modal` does not exist.

- [ ] **Step 3: Implement `tier_modal.py`** (mirror `key_modal.py`'s two-mode pattern):

```python
"""Claude tier remap picker — pick a tier, then a model_name. Select-only:
returns (tier, model); the app runs `harness alias set claude <tier> <model>`."""
from __future__ import annotations
from textual import on
from textual.app import ComposeResult
from textual.containers import Vertical
from textual.screen import ModalScreen
from textual.widgets import Label, ListItem, ListView


class TierMapModal(ModalScreen):
    BINDINGS = [("escape", "cancel", "Cancel")]

    def __init__(self, tiers: list[dict], models: list[str]) -> None:
        super().__init__()
        self._tiers = list(tiers)
        self._models = list(models)
        self._tier: str | None = None

    def compose(self) -> ComposeResult:
        with Vertical(id="tier-box"):
            yield Label("remap claude tier — pick tier", id="tier-title")
            yield ListView(id="tier-list")

    def on_mount(self) -> None:
        lv = self.query_one("#tier-list", ListView)
        for t in self._tiers:
            lv.append(ListItem(Label(f"{t['tier']}  ->  {t.get('model','')}"), name=t["tier"]))
        if self._tiers:
            lv.index = 0
        lv.focus()

    @on(ListView.Selected, "#tier-list")
    def _select(self, event: ListView.Selected) -> None:
        if self._tier is None:
            self._tier = event.item.name if event.item is not None else None
            if self._tier is None:
                return
            self.query_one("#tier-title", Label).update(f"remap {self._tier} — pick model")
            lv = self.query_one("#tier-list", ListView)
            lv.clear()
            for m in self._models:
                lv.append(ListItem(Label(m), name=m))
            if self._models:
                lv.index = 0
        else:
            model = event.item.name if event.item is not None else None
            if model is not None:
                self.dismiss((self._tier, model))

    def action_cancel(self) -> None:
        self.dismiss(None)
```

> Note: verify against textual 8.2.7 (READ the merged `key_modal.py`/`effort_modal.py` as references): `ListView.append/clear/index/focus`, `ListItem(name=…)`, `ListView.Selected.item.name`, `@on`. The reused `#tier-list` ListView switches contents from tiers to models in `_select`; the `self._tier is None` flag distinguishes the two modes. The 2 tests pin the behavior.

- [ ] **Step 4: Style in `app.tcss`** — append (mirror the other modals):

```css
TierMapModal { align: center middle; background: $background 60%; }
#tier-box { width: 56; height: auto; padding: 1 2; background: $surface; border: round $primary; }
#tier-title { margin-bottom: 1; color: $secondary; }
#tier-list { height: auto; max-height: 14; }
```

- [ ] **Step 5: Run tests + full suite**

Run: `cd config/ai-litellm && "$HOME/.local/share/ai-litellm-fabric/state/dash-venv/bin/python" -m pytest fabric_dash/tests/ -q`
Expected: PASS (the 2 tier-modal tests + all prior).

- [ ] **Step 6: Commit**

```bash
git add config/ai-litellm/fabric_dash/tier_modal.py config/ai-litellm/fabric_dash/app.tcss config/ai-litellm/fabric_dash/tests/test_app.py
git commit -m "feat(dash): TierMapModal (tier picker -> model picker)"
```

---

## Task 4: Wire `m` → `action_map` (Harnesses panel, claude)

**Files:**
- Modify: `config/ai-litellm/fabric_dash/app.py` (BINDINGS, `action_map`, `_actions_for`)
- Modify: `config/ai-litellm/fabric_dash/help.py` (`_KEYS`)
- Test: `config/ai-litellm/fabric_dash/tests/test_app.py`

**Interfaces:**
- Consumes: `TierMapModal` (Task 3), `client.harness_aliases` (Task 2), `client.model_list` (existing), `_run_argv` (P2), `_selected_harness`, the harnesses node id `"harnesses"`.
- Produces: `action_map` (a `@work` worker).

- [ ] **Step 1: Write the failing tests** — append to `tests/test_app.py`:

```python
@pytest.mark.asyncio
async def test_map_action_runs_alias_set_for_claude():
    calls = []
    def spawn(argv):
        calls.append(argv); return (0, ["Set claude opus -> Kimi-K2.6-openrouter"])
    from fabric_dash.actions import ActionRunner
    client = make_client()
    client.harness_aliases = lambda n: [{"tier": "fable", "model": "GLM-5.2-openrouter"}, {"tier": "opus", "model": "DeepSeek-V4-Pro-openrouter"}]
    client.model_list = lambda: [{"name": "GLM-5.2-openrouter"}, {"name": "Kimi-K2.6-openrouter"}]
    app = FabricApp(client=client, runner=ActionRunner(spawn=spawn))
    async with app.run_test() as pilot:
        await pilot.pause()
        app._selected = "harnesses"; app._selected_harness = "claude"
        await pilot.press("m"); await pilot.pause()      # opens TierMapModal
        from fabric_dash.tier_modal import TierMapModal
        assert isinstance(app.screen, TierMapModal)
        await pilot.press("down"); await pilot.press("enter"); await pilot.pause()  # tier=opus
        await pilot.press("down"); await pilot.press("enter"); await pilot.pause()  # model=Kimi
        assert calls == [["ai-litellm", "harness", "alias", "set", "claude", "opus", "Kimi-K2.6-openrouter"]]

@pytest.mark.asyncio
async def test_map_action_guarded_for_non_claude_and_other_panels():
    app = FabricApp(client=make_client())
    async with app.run_test() as pilot:
        await pilot.pause()
        app._selected = "harnesses"; app._selected_harness = "codex"   # not claude (P4b)
        await pilot.press("m"); await pilot.pause()
        from fabric_dash.tier_modal import TierMapModal
        assert not isinstance(app.screen, TierMapModal)                 # guarded
```

- [ ] **Step 2: Run to verify failure**

Run: `cd config/ai-litellm && "$HOME/.local/share/ai-litellm-fabric/state/dash-venv/bin/python" -m pytest fabric_dash/tests/test_app.py -k map_action -q`
Expected: FAIL — no `m` binding / `action_map`.

- [ ] **Step 3: Implement in `app.py`**:

(a) Add to the first BINDINGS list: `("m", "map", "Mapping")`.

(b) Add the worker action (mirror `action_effort`):

```python
    @work
    async def action_map(self) -> None:
        if self._selected != "harnesses" or self._selected_harness != "claude":
            self.query_one("#results", RichLog).write(
                "[yellow]select the claude harness first, then press m (codex mapping is P4b)[/]"
            )
            return
        tiers = await asyncio.to_thread(self.client.harness_aliases, "claude")
        models = [r.get("name") for r in await asyncio.to_thread(self.client.model_list) if r.get("name")]
        if not tiers or not models:
            self.query_one("#results", RichLog).write("[yellow]no tiers/models to map[/]")
            return
        from .tier_modal import TierMapModal
        choice = await self.push_screen_wait(TierMapModal(tiers, models))
        if choice is None:
            return
        tier, model = choice
        await self._run_argv(["harness", "alias", "set", "claude", tier, model],
                             label=f"alias set claude {tier}")
```

(c) In `_actions_for`, surface the action on the Harnesses panel:

```python
        if node_id == "harnesses":
            items.append(FooterItem("m", "mapping", SAFE, False))
```

- [ ] **Step 4: Add the help entry** — in `help.py` `_KEYS`, add `("m", "remap claude tier (Harnesses)")`. Keep accurate; the P1 help test must still pass.

- [ ] **Step 5: Run the full suite**

Run: `cd config/ai-litellm && "$HOME/.local/share/ai-litellm-fabric/state/dash-venv/bin/python" -m pytest fabric_dash/tests/ -q`
Expected: PASS — the 2 new tests + all prior. (`classify(["harness","alias","set",…])` is SAFE → no ConfirmModal; the backend "Run sync" line lands in `#results`.)

- [ ] **Step 6: Commit**

```bash
git add config/ai-litellm/fabric_dash/app.py config/ai-litellm/fabric_dash/help.py config/ai-litellm/fabric_dash/tests/test_app.py
git commit -m "feat(dash): m -> remap claude tier on Harnesses (gated via _run_argv)"
```

---

## Self-Review

**Spec coverage (§15):** Task 1 = backend `harness alias get --json` + `set` (validate model exists; derive direct+labels for cloud; preserve direct for local + warn; atomic write of the 4 keys) + check round-trip. Task 2 = client read. Task 3 = TierMapModal (tier picker → model picker). Task 4 = `m`/`action_map` guarded to harnesses+claude, runs `alias set` via `_run_argv` (SAFE), action-bar + help. codex = P4b (the `m` guard explicitly excludes non-claude). The "Run sync" reminder rides the backend output (DRY). No tier add/remove. No P1-P3b regression.

**Placeholder scan:** The `> Note:` blocks are concrete verification instructions (Textual 8.2.7 APIs via the merged key_modal.py/effort_modal.py; `$AI_LITELLM_CONFIG`/`ai_litellm_harness_json_array` existence; check.zsh model names) with named references — the pattern P1-P3b used. Backend code is grounded in the real settings.json (aliases/directAliases/displayNames/directDisplayNames), `ai_litellm_harness_json` / `ai_litellm_ruby` / atomic-write idioms.

**Type consistency:** `harness_aliases(name) -> list[dict {tier,model,direct,label}]` (Task 2) consumed by `action_map` (Task 4) and passed to `TierMapModal(tiers, models)` (Task 3). `TierMapModal` dismisses `(tier, model) | None`, handled in `action_map` → `_run_argv(["harness","alias","set","claude",tier,model])` — matching the Task 1 CLI surface. `model_list()` (existing) supplies the `models` list of `name`s.

---

*Next: P4b (codex facade mapping editor — reuse `harness alias` + the `m`/TierMapModal pattern with harness=codex; codex facade structure differs, confirm its settings keys). See docs/superpowers/specs/2026-06-20-fabric-control-surface-v2-design.md §15.*
