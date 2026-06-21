# fabric v2 — P4b: Codex Facade Mapping Editor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remap a codex facade (gpt-5.5/gpt-5.4/gpt-5.4-mini/gpt-5.2/gpt-5.3-codex) to a different backend from the `fabric` TUI: on the Harnesses panel select codex, press `m`, pick a facade, pick a source model — and the backend copies that source's `litellm_params` block + `model_info: *anchor` line onto the facade's `litellm_config.yaml` entry (anchor-preserving, line-based). This is the final v2 phase.

**Architecture:** A new backend `codex facade get/set` command owns the logic. `set` does a LINE-BASED edit of `config/litellm_config.yaml` (YAML load/dump is forbidden — it expands `*anchor` aliases and corrupts the config), reusing the existing `entry_range` model_list-entry locator: it keeps the facade's `- model_name:` line and replaces the entry BODY (litellm_params block + model_info line) with the source model_name's body — so the backend, api fields, and the `*anchor` alias copy verbatim and caps stay consistent. The TUI is a thin caller: a two-mode picker (facade → source model) returns `(facade, model)`, and the app runs `codex facade set <facade> <model>` through the existing gated `_run_argv` (SAFE → immediate). Also fixes a P4a-deferred local-label cosmetic bug.

**Tech Stack:** zsh (lib.zsh polyglot, line-based YAML edit), Python 3 + Textual 8.2.7, pytest + Pilot, package venv; `check.zsh`.

## Global Constraints

- ALL dash python under the venv: `cd config/ai-litellm && "$HOME/.local/share/ai-litellm-fabric/state/dash-venv/bin/python" -m pytest fabric_dash/tests/ -q`. Backend gate: `AI_LITELLM_SKIP_DASH_VENV=1 zsh scripts/check.zsh`. Branch `feat/fabric-v2-p4b-codex-mapping`; do NOT switch branches. (spec §3)
- **backend owns logic, TUI is a caller** — the TUI never edits litellm_config.yaml; it calls `ai-litellm codex facade …`. `facade get --json` is READ-ONLY additive (`[]`-safe). (spec §3, §16)
- **ANCHOR PRESERVATION (load-bearing):** `facade set` edits `config/litellm_config.yaml` LINE-BASED — never via YAML load/dump (which expands `model_info: *glm52` aliases, corrupting the config + bloating it + breaking the budget-anchor structure). Reuse the existing `entry_range(lines, name)` helper. After a set, the facade's `model_info:` line must still be the `*anchor` ALIAS (e.g. `model_info: *deepseek_v4_pro`), not inlined. (spec §16; mirrors `ai_litellm_model_reasoning_update`'s line editing)
- **Caps consistency:** remapping copies the source entry's `litellm_params` (model + api fields) AND its `model_info: *anchor` line together — so context/output caps (which feed the budget formula) move with the backend. (spec §16)
- **Single risk oracle / gate reuse** — `codex facade set` classifies SAFE → immediate via the existing `_run_argv`, no new ConfirmModal. The backend's "run sync" reminder rides the output to the log (DRY). (spec §12, §16)
- **No facade add/remove; codex nickname aliases (codex-litellm/settings.json) are out of scope.** No secrets. (spec §16)
- No P1–P4a regression — incl. the budget differential test (`scripts/verify_budget_consistency.py`); if line counts in lib.zsh shift, update its `*_RANGE` constants and confirm the slice-guards still pass. Tests make ZERO real subprocess/network calls. (spec §3, §10)

---

## File Structure

- Modify: `config/ai-litellm/lib.zsh` — `ai_litellm_codex_facade_json` (read) + `ai_litellm_codex_facade_set` (line-based copy) + a `codex)` arm in the main dispatcher; AND fix the P4a local-label derivation in `ai_litellm_harness_alias_set`.
- Modify: `scripts/check.zsh` — facade get/set round-trip + anchor-preservation assertion.
- Modify: `config/ai-litellm/fabric_dash/client.py` — `codex_facades()` read method.
- Modify: `config/ai-litellm/fabric_dash/tier_modal.py` — generalize `TierMapModal` to take a `name_key` + `title` (default `"tier"` so P4a is unchanged) so codex facades reuse it (DRY).
- Modify: `config/ai-litellm/fabric_dash/app.py` — `action_map` codex branch; relax the `m` guard to claude+codex.
- Modify: `config/ai-litellm/fabric_dash/help.py` — update the `m` keymap entry text.
- Test: `tests/test_client.py`, `tests/test_app.py` (additions).

---

## Task 1: Backend `codex facade get/set` (line-based, anchor-preserving) + P4a label fix

**Files:**
- Modify: `config/ai-litellm/lib.zsh` (add the two functions + a `codex)` dispatcher arm next to `model)`/`harness)` at ~line 6238; fix `ai_litellm_harness_alias_set`'s label derivation)
- Modify: `scripts/check.zsh`

**Interfaces:**
- Produces (CLI): `ai-litellm codex facade get --json` → `[{"facade","model","info"}, …]`; `ai-litellm codex facade set <facade> <source_model_name>` → copies source's body onto the facade's litellm_config entry (anchor-preserving), prints confirmation + "Run 'ai-litellm sync' …".

- [ ] **Step 1: Add the read function** — in `lib.zsh`, line-scan litellm_config for the codex facade entries. The facades are a known set; emit each facade's current `model:` and `model_info:` (the `*anchor` text). Match the file's `--json` idiom (reuse `ai_litellm_ruby`):

```zsh
ai_litellm_codex_facade_json() {
  ai_litellm_ruby -rjson -e '
    facades = %w[gpt-5.5 gpt-5.4 gpt-5.4-mini gpt-5.2 gpt-5.3-codex]
    lines = File.read(ARGV[0]).lines
    out = []
    facades.each do |f|
      si = lines.index { |l| l.match?(/^  - model_name:\s*#{Regexp.escape(f)}\s*$/) }
      next unless si
      fi = ((si+1)...lines.length).find { |i| lines[i].match?(/^  - model_name:\s*/) } || lines.length
      body = lines[si...fi]
      model = (body.find { |l| l =~ /^      model:\s*(\S.*)$/ } && $1)
      info  = (body.find { |l| l =~ /^    model_info:\s*(\S.*)$/ } && $1)
      out << {"facade" => f, "model" => model, "info" => info}
    end
    puts JSON.generate(out)
  ' "$AI_LITELLM_CONFIG" 2>/dev/null || printf '[]'
}
```

- [ ] **Step 2: Add the set function (line-based body copy, anchor-preserving)** — keep the facade's `- model_name:` line; replace its BODY (everything from the next line to the entry end) with the source entry's body. Reuse the `entry_range` idiom (lib.zsh ~4077):

```zsh
ai_litellm_codex_facade_set() {
  local facade="${1:-}" source="${2:-}"
  if [[ -z "$facade" || -z "$source" ]]; then
    echo "Usage: ai-litellm codex facade set <facade> <source_model_name>" >&2
    return 1
  fi
  ai_litellm_ruby -e '
    config_path, facade, source = ARGV
    lines = File.read(config_path).lines
    er = lambda do |name|
      s = lines.index { |l| l.match?(/^  - model_name:\s*#{Regexp.escape(name)}\s*$/) }
      next nil unless s
      f = ((s+1)...lines.length).find { |i| lines[i].match?(/^  - model_name:\s*/) } || lines.length
      [s, f]
    end
    fr = er.call(facade) or abort("Unknown codex facade: #{facade}")
    sr = er.call(source) or abort("Unknown source model_name: #{source}")
    # body = entry lines after the `- model_name:` line, trailing blank lines trimmed
    body = lambda do |s, f|
      b = lines[(s+1)...f]
      b.pop while b.any? && b.last.strip.empty?
      b
    end
    src_body = body.call(*sr)
    fs, ff = fr
    fbody = body.call(fs, ff)
    # replace facade body in place, keep one blank line after if the original had a separator
    new_lines = lines[0..fs] + src_body + ["\n"] + lines[(fs + 1 + fbody.length)..-1].to_a
    # drop a leading extra blank if we just added one and the tail already starts blank
    new_lines.delete_at(fs + 1 + src_body.length) if new_lines[fs + 1 + src_body.length].to_s.strip.empty? && new_lines[fs + src_body.length].to_s == "\n"
    tmp = "#{config_path}.tmp.#{$$}"
    File.write(tmp, new_lines.join)
    File.rename(tmp, config_path)
  ' "$AI_LITELLM_CONFIG" "$facade" "$source" || return $?
  echo "Set codex facade $facade -> $source"
  echo "Run 'ai-litellm sync' to apply it to the running proxy."
}
```

> Note: the blank-line handling between entries is the fiddly part — verify with the anchor-preservation + round-trip check (Step 4) and a `yaml`-parse sanity check; iterate the body/blank logic until the round-trip leaves litellm_config byte-identical AND `model_info:` stays a `*anchor` alias. The REQUIREMENT: facade `- model_name:` preserved; body (litellm_params + model_info) replaced by the source's; the `*anchor` alias line copied verbatim (NOT expanded); all other entries untouched.

- [ ] **Step 3: Fix the P4a local-label derivation** — in `ai_litellm_harness_alias_set` (lib.zsh, from P4a), the proxy `displayNames` label for LOCAL targets is wrong (`"Gemma4-12B-omlx (openai)"`). Derive the label from the MODEL_NAME's own trailing token instead of the backend provider — works for cloud+local:

```ruby
    # was: name = model.sub(/-#{Regexp.escape(provider)}$/, ""); label "(provider)"
    name, suffix = model.rpartition("-").values_at(0, 2)
    name = model if name.empty?      # model_name without a trailing -<x>
    label = "#{name} (#{suffix.empty? ? provider : suffix})"
    (settings["displayNames"] ||= {})[tier] = label
```
Apply the same `label` to `directDisplayNames` on the cloud branch. (So `GLM-5.2-openrouter` → `GLM-5.2 (openrouter)`, `Gemma4-12B-omlx` → `Gemma4-12B (omlx)`.)

- [ ] **Step 4: Add the dispatch + check.zsh** — add a `codex)` arm to the main dispatcher (next to `model)`/`harness)` ~line 6238) routing to a small `ai_litellm_cmd_codex` that handles `facade get [--json]` / `facade set <facade> <source>`. Then check.zsh assertions (round-trip + anchor preservation):

```zsh
f_json="$(ai-litellm codex facade get --json 2>/dev/null)"
echo "$f_json" | jq -e 'type=="array" and length>=5 and (.[0]|has("facade") and has("model"))' >/dev/null \
  || { echo "FAIL: codex facade get --json"; exit 1; }
orig_model="$(ai-litellm codex facade get --json | jq -r '.[]|select(.facade=="gpt-5.5").model')"
ai-litellm codex facade set gpt-5.5 DeepSeek-V4-Pro-openrouter >/dev/null 2>&1
now_model="$(ai-litellm codex facade get --json | jq -r '.[]|select(.facade=="gpt-5.5").model')"
now_info="$(ai-litellm codex facade get --json | jq -r '.[]|select(.facade=="gpt-5.5").info')"
ai-litellm sync --dry-run >/dev/null 2>&1 || true   # config still parses
# restore (gpt-5.5 was GLM-5.2 backend; copy from a model_name with that backend)
ai-litellm codex facade set gpt-5.5 GLM-5.2-openrouter >/dev/null 2>&1
[[ "$now_model" == *deepseek* && "$now_info" == "*deepseek_v4_pro" ]] \
  || { echo "FAIL: codex facade set (model + anchor-alias)"; exit 1; }
git diff --quiet config/litellm_config.yaml \
  || { echo "FAIL: codex facade round-trip not byte-identical"; git checkout config/litellm_config.yaml; exit 1; }
echo "ok: codex facade get/set (anchor-preserving round-trip)"
```

> Note: the restore must reproduce gpt-5.5's ORIGINAL body. Since gpt-5.5 originally copies the GLM-5.2 backend (`*glm52`), restoring from `GLM-5.2-openrouter` (whose body is `model: openrouter/z-ai/glm-5.2` + `model_info: *glm52`) should reproduce it — VERIFY `git diff config/litellm_config.yaml` is empty after restore; if the source body differs from gpt-5.5's original (e.g. comments), capture+restore the original lines instead. The `*now_info == "*deepseek_v4_pro"` assertion proves the anchor alias was copied (not expanded).

- [ ] **Step 5: Run the backend gate**

Run: `AI_LITELLM_SKIP_DASH_VENV=1 zsh scripts/check.zsh`
Expected: exit 0, including "ok: codex facade get/set …". Confirm by hand: `ai-litellm codex facade get --json | jq .` lists 5 facades; a set+restore leaves `git diff config/litellm_config.yaml` empty; after a set, `grep 'model_info:' config/litellm_config.yaml` shows the facade still uses a `*anchor` alias (not inlined). If lib.zsh line counts shifted, update `verify_budget_consistency.py` `*_RANGE` constants and re-confirm.

- [ ] **Step 6: Commit**

```bash
git add config/ai-litellm/lib.zsh scripts/check.zsh
git commit -m "feat(cli): codex facade get/set (line-based, anchor-preserving) + fix P4a local label"
```

---

## Task 2: FabricClient facade read

**Files:**
- Modify: `config/ai-litellm/fabric_dash/client.py`
- Test: `config/ai-litellm/fabric_dash/tests/test_client.py`

**Interfaces:**
- Produces: `FabricClient.codex_facades() -> list` — `[{"facade","model","info"}, …]`, `[]` on failure.

- [ ] **Step 1: Write the failing test** — append to `tests/test_client.py`:

```python
def test_codex_facades_read():
    from fabric_dash.client import FabricClient
    seen = []
    def run(argv):
        seen.append(argv)
        if argv[:3] == ["ai-litellm", "codex", "facade"]:
            return (0, '[{"facade":"gpt-5.5","model":"openrouter/z-ai/glm-5.2","info":"*glm52"}]')
        return (1, "")
    c = FabricClient(runner=run)
    rows = c.codex_facades()
    assert rows[0]["facade"] == "gpt-5.5"
    assert ["ai-litellm", "codex", "facade", "get", "--json"] in seen
    assert FabricClient(runner=lambda a: (1, "")).codex_facades() == []
```

- [ ] **Step 2: Run to verify failure**

Run: `cd config/ai-litellm && "$HOME/.local/share/ai-litellm-fabric/state/dash-venv/bin/python" -m pytest fabric_dash/tests/test_client.py::test_codex_facades_read -q`
Expected: FAIL — method doesn't exist.

- [ ] **Step 3: Implement** — in `client.py`, add:

```python
    def codex_facades(self) -> list:
        return self._arr("codex", "facade", "get", "--json")
```

- [ ] **Step 4: Run to verify pass**

Run: `cd config/ai-litellm && "$HOME/.local/share/ai-litellm-fabric/state/dash-venv/bin/python" -m pytest fabric_dash/tests/ -q`
Expected: PASS (all).

- [ ] **Step 5: Commit**

```bash
git add config/ai-litellm/fabric_dash/client.py config/ai-litellm/fabric_dash/tests/test_client.py
git commit -m "feat(dash): FabricClient.codex_facades read"
```

---

## Task 3: Generalize `TierMapModal` for reuse by facades

**Files:**
- Modify: `config/ai-litellm/fabric_dash/tier_modal.py`
- Test: `config/ai-litellm/fabric_dash/tests/test_app.py`

**Interfaces:**
- Consumes: nothing new.
- Produces: `TierMapModal(rows, models, name_key="tier", title="remap claude tier — pick row")` — the same two-mode picker, now generic over the row's name field (`name_key`) and title, so codex facades pass `name_key="facade"`. Dismisses `(name, model)` or `None`. (P4a's `TierMapModal(tiers, models)` call keeps working via the defaults.)

- [ ] **Step 1: Write the failing test** — append to `tests/test_app.py` (a facade-shaped usage):

```python
@pytest.mark.asyncio
async def test_tier_modal_generic_name_key_for_facades():
    from fabric_dash.tier_modal import TierMapModal
    captured = {}
    rows = [{"facade": "gpt-5.5", "model": "openrouter/z-ai/glm-5.2"},
            {"facade": "gpt-5.4", "model": "openrouter/deepseek/deepseek-v4-pro"}]
    models = ["GLM-5.2-openrouter", "DeepSeek-V4-Pro-openrouter"]
    app = FabricApp(client=make_client())
    async with app.run_test() as pilot:
        await pilot.pause()
        async def grab():
            captured["c"] = await app.push_screen_wait(
                TierMapModal(rows, models, name_key="facade", title="remap codex facade"))
        app.run_worker(grab())
        await pilot.pause()
        await pilot.press("down"); await pilot.press("enter")   # facade=gpt-5.4
        await pilot.pause()
        await pilot.press("down"); await pilot.press("enter")   # model=DeepSeek
        await pilot.pause()
        assert captured["c"] == ("gpt-5.4", "DeepSeek-V4-Pro-openrouter")
```

- [ ] **Step 2: Run to verify failure**

Run: `cd config/ai-litellm && "$HOME/.local/share/ai-litellm-fabric/state/dash-venv/bin/python" -m pytest fabric_dash/tests/test_app.py::test_tier_modal_generic_name_key_for_facades -q`
Expected: FAIL — `TierMapModal` has no `name_key`/`title` params.

- [ ] **Step 3: Generalize `tier_modal.py`** — add the params; default `name_key="tier"` keeps P4a working. Use `name_key` where it currently reads `t["tier"]`, and `title` for the initial Label:

```python
    def __init__(self, rows: list[dict], models: list[str],
                 name_key: str = "tier", title: str = "remap claude tier — pick row") -> None:
        super().__init__()
        self._rows = list(rows)
        self._models = list(models)
        self._name_key = name_key
        self._title = title
        self._row: str | None = None

    def compose(self) -> ComposeResult:
        with Vertical(id="tier-box"):
            yield Label(self._title, id="tier-title")
            yield ListView(id="tier-list")

    def on_mount(self) -> None:
        lv = self.query_one("#tier-list", ListView)
        for r in self._rows:
            lv.append(ListItem(Label(f"{r[self._name_key]}  ->  {r.get('model','')}"), name=r[self._name_key]))
        if self._rows:
            lv.index = 0
        lv.focus()
```

(Keep the `_select` two-mode logic; it already reads `event.item.name`. Rename the internal `_tier` attr to `_row` consistently, or leave `_tier` — just keep it consistent within the file.)

> Note: P4a's existing tests call `TierMapModal(tiers, models)` — the new defaults (`name_key="tier"`) preserve that. Run the P4a tier-modal tests to confirm they still pass.

- [ ] **Step 4: Run tests + full suite**

Run: `cd config/ai-litellm && "$HOME/.local/share/ai-litellm-fabric/state/dash-venv/bin/python" -m pytest fabric_dash/tests/ -q`
Expected: PASS (the new generic test + the P4a tier-modal tests + all prior).

- [ ] **Step 5: Commit**

```bash
git add config/ai-litellm/fabric_dash/tier_modal.py config/ai-litellm/fabric_dash/tests/test_app.py
git commit -m "refactor(dash): generalize TierMapModal (name_key/title) for facade reuse"
```

---

## Task 4: Wire `action_map` codex branch (Harnesses → codex → m)

**Files:**
- Modify: `config/ai-litellm/fabric_dash/app.py` (`action_map`: add the codex branch; relax the guard)
- Modify: `config/ai-litellm/fabric_dash/help.py` (`_KEYS` text)
- Test: `config/ai-litellm/fabric_dash/tests/test_app.py`

**Interfaces:**
- Consumes: `client.codex_facades` (Task 2), `client.model_list` (existing), generalized `TierMapModal` (Task 3), `_run_argv` (P2).
- Produces: `action_map` handles both claude (tiers) and codex (facades).

- [ ] **Step 1: Write the failing tests** — append to `tests/test_app.py`:

```python
@pytest.mark.asyncio
async def test_map_action_runs_facade_set_for_codex():
    calls = []
    def spawn(argv):
        calls.append(argv); return (0, ["Set codex facade gpt-5.4 -> DeepSeek-V4-Pro-openrouter"])
    from fabric_dash.actions import ActionRunner
    client = make_client()
    client.codex_facades = lambda: [{"facade": "gpt-5.5", "model": "openrouter/z-ai/glm-5.2"}, {"facade": "gpt-5.4", "model": "openrouter/deepseek/deepseek-v4-pro"}]
    client.model_list = lambda: [{"name": "GLM-5.2-openrouter"}, {"name": "DeepSeek-V4-Pro-openrouter"}]
    app = FabricApp(client=client, runner=ActionRunner(spawn=spawn))
    async with app.run_test() as pilot:
        await pilot.pause()
        app._selected = "harnesses"; app._selected_harness = "codex"
        await pilot.press("m"); await pilot.pause()
        from fabric_dash.tier_modal import TierMapModal
        assert isinstance(app.screen, TierMapModal)
        await pilot.press("down"); await pilot.press("enter"); await pilot.pause()  # facade=gpt-5.4
        await pilot.press("down"); await pilot.press("enter"); await pilot.pause()  # model=DeepSeek
        assert calls == [["ai-litellm", "codex", "facade", "set", "gpt-5.4", "DeepSeek-V4-Pro-openrouter"]]

@pytest.mark.asyncio
async def test_map_action_still_guards_other_harness():
    app = FabricApp(client=make_client())
    async with app.run_test() as pilot:
        await pilot.pause()
        app._selected = "harnesses"; app._selected_harness = "goose"   # neither claude nor codex
        await pilot.press("m"); await pilot.pause()
        from fabric_dash.tier_modal import TierMapModal
        assert not isinstance(app.screen, TierMapModal)
```

- [ ] **Step 2: Run to verify failure**

Run: `cd config/ai-litellm && "$HOME/.local/share/ai-litellm-fabric/state/dash-venv/bin/python" -m pytest fabric_dash/tests/test_app.py -k "facade_set_for_codex or still_guards" -q`
Expected: FAIL — `action_map` has no codex branch (codex currently hits the guard hint).

- [ ] **Step 3: Implement in `app.py`** — replace the claude-only `action_map` body with a claude/codex dispatch:

```python
    @work
    async def action_map(self) -> None:
        if self._selected != "harnesses" or self._selected_harness not in ("claude", "codex"):
            self.query_one("#results", RichLog).write(
                "[yellow]select the claude or codex harness first, then press m[/]"
            )
            return
        models = [r.get("name") for r in await asyncio.to_thread(self.client.model_list) if r.get("name")]
        from .tier_modal import TierMapModal
        if self._selected_harness == "claude":
            rows = await asyncio.to_thread(self.client.harness_aliases, "claude")
            name_key, title, argv0 = "tier", "remap claude tier — pick tier", ["harness", "alias", "set", "claude"]
        else:  # codex
            rows = await asyncio.to_thread(self.client.codex_facades)
            name_key, title, argv0 = "facade", "remap codex facade — pick facade", ["codex", "facade", "set"]
        if not rows or not models:
            self.query_one("#results", RichLog).write("[yellow]nothing to map[/]")
            return
        choice = await self.push_screen_wait(TierMapModal(rows, models, name_key=name_key, title=title))
        if choice is None:
            return
        name, model = choice
        await self._run_argv(argv0 + [name, model], label=f"map {self._selected_harness} {name}")
```

> Note: this preserves P4a (claude → `harness alias set claude <tier> <model>`) and adds codex (→ `codex facade set <facade> <model>`). The guard now allows claude+codex.

- [ ] **Step 4: Update the help entry** — in `help.py` `_KEYS`, change the `m` entry to `("m", "remap tier/facade (claude/codex, Harnesses)")`. Keep the P1 help test passing.

- [ ] **Step 5: Run the full suite**

Run: `cd config/ai-litellm && "$HOME/.local/share/ai-litellm-fabric/state/dash-venv/bin/python" -m pytest fabric_dash/tests/ -q`
Expected: PASS — the 2 new tests + the P4a claude map test (still claude→harness alias) + all prior.

- [ ] **Step 6: Commit**

```bash
git add config/ai-litellm/fabric_dash/app.py config/ai-litellm/fabric_dash/help.py config/ai-litellm/fabric_dash/tests/test_app.py
git commit -m "feat(dash): m remaps codex facades too (Harnesses -> codex), reuses TierMapModal"
```

---

## Self-Review

**Spec coverage (§16):** Task 1 = backend `codex facade get --json` + `set` (line-based body copy preserving the `*anchor` alias + caps; reuses `entry_range`) + the P4a local-label fix + check round-trip with anchor-preservation assertion. Task 2 = client read. Task 3 = generalize `TierMapModal` (name_key/title) so facades reuse it (DRY; P4a defaults unchanged). Task 4 = `action_map` codex branch (claude→harness alias / codex→codex facade), guard relaxed to claude+codex, help updated. codex nickname aliases + facade add/remove out of scope. The "run sync" reminder rides backend output. No P1–P4a regression.

**Placeholder scan:** The `> Note:` blocks are concrete verification instructions (blank-line/anchor iteration against check; `verify_budget_consistency.py` ranges; P4a tier-modal tests still pass) — the pattern P1–P4a used. Backend code is grounded in the real `entry_range` helper + the line-edit idiom + the verified facade entries (gpt-5.5…gpt-5.3-codex with `*glm52`/`*deepseek_v4_pro`/etc.).

**Type consistency:** `codex_facades() -> list[dict {facade,model,info}]` (Task 2) → `action_map` (Task 4) passes `rows` + `name_key="facade"` to the generalized `TierMapModal(rows, models, name_key, title)` (Task 3), which dismisses `(name, model)` → `_run_argv(["codex","facade","set",name,model])` matching the Task 1 CLI. The claude path keeps `name_key="tier"` + `["harness","alias","set","claude",…]`.

---

*P4b is the final v2 phase. After merge, the v2 control-surface effort (P1 design → P2 palette → P3 reasoning → P3b keys → P4a claude mapping → P4b codex mapping) is complete. See docs/superpowers/specs/2026-06-20-fabric-control-surface-v2-design.md.*
