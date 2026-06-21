"""fabric — read-only control-plane TUI over ai-litellm."""
from __future__ import annotations
import asyncio
from pathlib import Path
from rich.text import Text
from textual.app import App, ComposeResult
from textual.containers import Horizontal
from textual.theme import Theme
from textual.widgets import Header, Tree, Static, RichLog, DataTable
from textual import work
from .client import FabricClient
from .safety import ACTIONS, BILLABLE, SAFE, classify
from .actions import ActionRunner
from .modal import ConfirmModal
from .footer import StatusFooter, FooterItem

_FABRIC_THEME = Theme(
    name="fabric",
    primary="#4c9aff",      # calm steel-blue accent (panels/borders)
    secondary="#9aa7b3",    # muted slate (titles/headers)
    success="#3fb950",      # green  = ok / ready
    warning="#d29922",      # amber  = stale / disruptive
    error="#f85149",        # red    = fail / missing / billable
    background="#0d1117",
    surface="#161b22",
    panel="#1c2128",
    dark=True,
)

CONCEPTS = [
    ("proxy", "Proxy"),
    ("harnesses", "Harnesses"),
    ("models", "Models / Routes"),
    ("runtimes", "Runtimes"),
    ("budget", "Budget & Policy"),
    ("keys", "Keys"),
]

# Friendly labels for raw --json dict keys, so panels don't read as a wall of
# camelCase. Unmapped keys fall back to a title-cased version of the key.
COLUMN_LABELS = {
    "name": "Name",
    "model": "Model",
    "backend": "Backend",
    "adapter": "Adapter",
    "valid": "Valid",
    "cliInstalled": "CLI",
    "tpm": "TPM",
    "rpm": "RPM",
    "maxOut": "Max Out",
    "maxIn": "Max In",
    "source": "Source",
}


def _label(key: str) -> str:
    return COLUMN_LABELS.get(key, key[:1].upper() + key[1:])


# Status color system (mirrors app.tcss .ok/.warn/.bad → $success/$warning/$error).
# Load-bearing: readiness columns must signal danger before a billable launch.
_OK = "green"
_BAD = "red"
# Columns whose truthiness is a readiness signal: False → red, True → green.
_BOOL_READY_KEYS = {"valid", "cliInstalled"}
# Key-status sources that mean "this key is not usable" → red.
_BAD_SOURCES = {"missing", "unset", "none", ""}


def _format_value(value) -> str:
    """Human-readable scalar for a table cell. Dicts/lists are flattened to a
    compact ' / '-joined string of their values (the --json `sources` field is a
    dict like {'context': 'provider', 'output': 'owned-policy'}) instead of a raw
    Python repr leaking into the UI."""
    if value is None:
        return ""
    if isinstance(value, dict):
        return " / ".join(_format_value(v) for v in value.values())
    if isinstance(value, (list, tuple)):
        return " / ".join(_format_value(v) for v in value)
    if isinstance(value, bool):
        return "yes" if value else "no"
    return str(value)


def _cell(key: str, value) -> Text:
    """Render one table cell, coloring readiness signals per the status system."""
    if key in _BOOL_READY_KEYS or isinstance(value, bool):
        truthy = value is True or str(value).strip().lower() in ("true", "yes", "1")
        return Text("✓" if truthy else "✗", style=_OK if truthy else _BAD)
    text = _format_value(value)
    if key in ("source", "sources") and text.strip().lower() in _BAD_SOURCES:
        return Text(text, style=_BAD)
    return Text(text)


class FabricApp(App):
    CSS_PATH = Path(__file__).parent / "app.tcss"
    TITLE = "ai-litellm fabric"
    ENABLE_COMMAND_PALETTE = False  # we bind ctrl+p to our own CommandPalette
    BINDINGS = (
        [("q", "quit", "Quit"), ("r", "refresh", "Refresh"), ("l", "launch", "Launch"),
         ("e", "effort", "Reasoning"), ("k", "key", "Set key"), ("m", "map", "Mapping"),
         ("question_mark", "help", "Help"), ("colon", "palette", "Commands"), ("ctrl+p", "palette", "Commands")]
        + [(a.key, f"do_{a.key}", a.label) for a in ACTIONS]
    )

    def _actions_for(self, node_id: str) -> list[FooterItem]:
        """Contextual action bar for the given panel.

        Global set: quit, refresh, and the SAFE actions are always present.
        Mutating group: the non-SAFE actions are always shown.
        Contextual: launch (billable) appears ONLY on the harnesses panel —
        it is the harnesses panel's primary action, and meaningless elsewhere.
        Reuses each action's safety grade so color encodes risk consistently."""
        # Read-only group: quit, refresh, the SAFE actions (start, doctor), and help.
        items = [
            FooterItem("q", "quit", "quit", False),
            FooterItem("r", "refresh", SAFE, False),
        ]
        items += [
            FooterItem(a.key, a.label, a.grade, False)
            for a in ACTIONS if a.grade == SAFE
        ]
        items.append(FooterItem("?", "help", SAFE, False))
        # Mutating group: launch only on harnesses, then the non-SAFE actions.
        if node_id == "harnesses":
            items.append(FooterItem("l", "launch", BILLABLE, True))
            items.append(FooterItem("m", "mapping", SAFE, False))
        if node_id in ("models", "harnesses"):
            items.append(FooterItem("e", "reasoning", SAFE, False))
        if node_id == "keys":
            items.append(FooterItem("k", "set key", SAFE, False))
        items += [
            FooterItem(a.key, a.label, a.grade, True)
            for a in ACTIONS if a.grade != SAFE
        ]
        return items

    def __init__(self, client: FabricClient | None = None, runner: ActionRunner | None = None):
        super().__init__()
        self.client = client or FabricClient()
        self.runner = runner or ActionRunner()
        self._selected = "proxy"
        self._selected_harness: str | None = None
        self._selected_model: str | None = None
        self._refresh_in_flight = False

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
            # One reusable table for every wide tabular view (harnesses, models,
            # runtimes, budget). DataTable sizes columns to content and scrolls,
            # so rows never wrap the way fixed-width text columns did.
            table: DataTable = DataTable(id="data-table", cursor_type="row", zebra_stripes=True)
            table.display = False  # shown only on tabular panels
            yield table
        yield RichLog(id="results", highlight=False, markup=True)
        yield StatusFooter(id="footer")

    async def on_mount(self) -> None:
        self.register_theme(_FABRIC_THEME)
        self.theme = "fabric"
        self.query_one("#concepts", Tree).border_title = "Concepts"
        self.query_one("#results", RichLog).border_title = "Results"
        self.query_one("#footer", StatusFooter).set_items(self._actions_for(self._selected))
        await self.refresh_status()
        await self.show_panel("proxy")
        self.set_interval(4.0, self.refresh_status)  # safe/read-only auto-refresh only

    def on_tree_node_selected(self, event: Tree.NodeSelected) -> None:
        node_id = event.node.data
        if node_id:
            self._selected = node_id
            self.query_one("#footer", StatusFooter).set_items(self._actions_for(node_id))
            # Render off the event loop: panel reads are blocking subprocesses
            # (~15s timeout each). An exclusive worker also supersedes a still-
            # running render if the user navigates again before it finishes.
            # Known limitations (round-2 review, judged acceptable): (1) cancelling
            # the worker cancels the asyncio task but NOT the offloaded
            # subprocess thread — it runs to its 15s timeout, so the thread pool
            # self-drains within 15s even under spammed navigation against a dead
            # proxy. (2) action_refresh/action_launch render inline (awaited, not
            # via this group) — render steps after the await are synchronous and
            # atomic on the loop, so concurrent renders converge; they are not
            # routed here because they must sequence work after the render.
            self.run_worker(self.show_panel(node_id), exclusive=True, group="panel")

    async def action_refresh(self) -> None:
        await self.refresh_status()
        await self.show_panel(self._selected)

    def action_help(self) -> None:
        from .help import HelpOverlay
        self.push_screen(HelpOverlay())

    @work
    async def action_palette(self) -> None:
        from .palette import CommandPalette
        from .commands import COMMANDS
        choice = await self.push_screen_wait(CommandPalette(COMMANDS))
        if not choice:
            return
        label, argv = choice
        await self._run_argv(argv, label)

    async def refresh_status(self) -> None:
        # Re-entrancy guard: if a refresh is already in flight (e.g. the proxy
        # is unreachable and the 15s timeout is running), skip this tick rather
        # than starting back-to-back blocking reads that pin a worker thread.
        if self._refresh_in_flight:
            return
        self._refresh_in_flight = True
        try:
            await self._refresh_status_body()
        finally:
            self._refresh_in_flight = False

    async def _refresh_status_body(self) -> None:
        # Offload the blocking subprocess call to a thread pool so the event
        # loop is free during the ~15s timeout window (pre-merge P1 fix).
        s = await asyncio.to_thread(self.client.proxy_status)
        # Widget mutation must happen on the main thread — we are back on the
        # event loop here (asyncio.to_thread returns to the calling coroutine).
        health = s.get("health", "unknown")
        cur = s.get("configCurrency", "unknown")
        url = s.get("baseUrl", "")
        dot = {"ok": "[green]o[/]", "unreachable": "[red]x[/]"}.get(health, "[yellow]?[/]")
        badge = "[yellow]STALE -> sync[/]" if cur == "stale" else f"[dim]{cur}[/]"
        if self._selected_harness:
            launch = f"[dim]launch ->[/] {self._selected_harness}"
        else:
            # Make the dependency discoverable: 'l' is meaningless until a
            # harness is picked, so point the newcomer at the Harnesses panel.
            # Escape the brackets (\[) so Rich renders them literally instead of
            # parsing "[open Harnesses]" as a markup tag and silently dropping it.
            launch = "[dim]launch ->[/] [yellow]\\[open Harnesses][/]"
        self.query_one("#status", Static).update(
            f"{dot} proxy: {health}   config: {badge}   {launch}   [dim]{url}[/]"
        )

    # Panels that render as a wide table; empty-state message shown otherwise.
    _EMPTY = {
        "harnesses": "no harnesses",
        "models": "no models / routes (is the proxy synced?)",
        "runtimes": "no runtimes",
        "budget": "no reasoning matrix",
    }

    async def show_panel(self, node_id: str) -> None:
        content = self.query_one("#content", Static)
        table = self.query_one("#data-table", DataTable)
        # Set the panel title to the human label for this concept node.
        title = next((lbl for nid, lbl in CONCEPTS if nid == node_id), node_id)
        content.border_title = title
        table.border_title = title
        # Default: text panel visible, table hidden.
        content.display = True
        table.display = False
        # Every branch's data comes from a blocking subprocess.run(timeout=15);
        # offload it so an unreachable proxy can't freeze the event loop (same
        # pre-merge fix already applied to the status bar). Widget mutation stays
        # on the event loop, after the await.
        if node_id == "proxy":
            content.update(await asyncio.to_thread(self._proxy_text))
        elif node_id == "keys":
            content.update(await asyncio.to_thread(self._keys_text) or "no keys")
        elif node_id in self._EMPTY:
            rows = await asyncio.to_thread(self._panel_rows, node_id)
            if rows:
                self._fill_table(table, rows, select=(node_id == "harnesses"))
                content.display = False
                table.display = True
            else:
                if node_id == "harnesses":
                    self._selected_harness = None
                content.update(self._EMPTY[node_id])
        else:
            content.update("")

    def _panel_rows(self, node_id: str) -> list:
        if node_id == "harnesses":
            return self.client.harness_list()
        if node_id == "models":
            return self.client.model_limits() or self.client.model_list()
        if node_id == "runtimes":
            return self.client.runtime_status()
        if node_id == "budget":
            return self.client.reasoning_matrix()
        return []

    # Field-level coloring for the proxy panel, so the larger surface carries the
    # same green/amber/red signal the status bar already shows for these facts.
    _WARN = "yellow"

    def _proxy_text(self) -> Text:
        """Proxy status as bold-keyed, status-colored key:value lines."""
        s = self.client.proxy_status()
        if not s:
            return Text("proxy not running — press s to start it", style=_BAD)
        out = Text()
        for i, (k, v) in enumerate(s.items()):
            if i:
                out.append("\n")
            out.append(f"{_label(k)}: ", style="bold")
            text = "" if v is None else str(v)
            style = ""
            low = text.strip().lower()
            if k == "health":
                style = _OK if low == "ok" else (_BAD if low == "unreachable" else self._WARN)
            elif k == "configCurrency":
                style = self._WARN if low == "stale" else _OK
            out.append(text, style=style)
        return out

    def _keys_text(self) -> Text:
        """Key status as colored lines: missing/unset keys render red (load-bearing)."""
        out = Text()
        for i, (name, info) in enumerate(self.client.key_status().items()):
            src = str(info.get("source", "?"))
            bad = src.strip().lower() in _BAD_SOURCES
            if i:
                out.append("\n")
            out.append(f"{name}: ")
            out.append(src, style=_BAD if bad else _OK)
        return out

    @staticmethod
    def _row_label(row: dict) -> str:
        """Human label for a row: harnesses key on `name`, models on `model`."""
        return str(row.get("name") or row.get("model") or "")

    def _fill_table(self, table: DataTable, rows: list, *, select: bool) -> None:
        """Render rows into the shared DataTable with status-colored cells.

        Row keys must be unique *and* name-independent: ``model limits``/``model
        list`` rows have no ``name`` field, so keying on ``name`` alone collides
        on "" for every row → textual DuplicateKey → app teardown. We key on the
        row label plus its index, which is always unique. on_data_table_row_
        highlighted recovers the label by splitting on the trailing "#<i>".

        When ``select`` is set, the first row seeds the launch target so 'l'
        always has a real harness to hand off to.
        """
        table.clear(columns=True)
        if not rows:
            return
        cols = list(rows[0].keys())
        for c in cols:
            table.add_column(_label(c), key=c)
        for i, r in enumerate(rows):
            table.add_row(
                *[_cell(c, r.get(c)) for c in cols],
                key=f"{self._row_label(r)}#{i}",
            )
        if select and self._selected_harness is None:
            self._selected_harness = self._row_label(rows[0]) or None
            self.call_later(self.refresh_status)

    def on_data_table_row_highlighted(self, event: DataTable.RowHighlighted) -> None:
        # Only the Harnesses panel drives the launch target.
        if (
            event.data_table.id == "data-table"
            and self._selected == "harnesses"
            and event.row_key is not None
            and event.row_key.value is not None
        ):
            # Row keys are "<label>#<i>"; strip the disambiguating index suffix.
            self._selected_harness = str(event.row_key.value).rsplit("#", 1)[0] or None
            self.call_later(self.refresh_status)
        if (
            event.data_table.id == "data-table"
            and self._selected == "models"
            and event.row_key is not None
            and event.row_key.value is not None
        ):
            self._selected_model = str(event.row_key.value).rsplit("#", 1)[0] or None

    # --- action helpers ---

    def _action_by_key(self, key: str):
        for a in ACTIONS:
            if a.key == key:
                return a
        return None

    async def _run_argv(self, argv: list[str], label: str | None = None,
                        consequence: str | None = None, stdin_input: str | None = None) -> None:
        """Shared command execution core: gate by classify(argv), offload the
        blocking subprocess off the event loop, stream results to the log.
        Awaited from a worker (callers are @work) so push_screen_wait works."""
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

    @work
    async def _run_action(self, key: str) -> None:
        """Run a registry action; @work provides the worker context needed by
        push_screen_wait. Delegates gate+offload+log to _run_argv."""
        a = self._action_by_key(key)
        if a is None:
            return
        await self._run_argv(list(a.argv), a.label, a.consequence)

    @work
    async def _run_argv_worker(self, argv: list[str], label: str | None = None) -> None:
        """Test-only worker entry: drives _run_argv from a worker context so a
        Pilot test can exercise the confirm gate. Production paths (action_palette,
        _run_action) await _run_argv directly from their own @work context."""
        await self._run_argv(argv, label)

    # Per-key action methods (explicit, not metaprogrammed); @work makes _run_action sync-callable
    def action_do_s(self) -> None: self._run_action("s")
    def action_do_d(self) -> None: self._run_action("d")
    def action_do_S(self) -> None: self._run_action("S")
    def action_do_R(self) -> None: self._run_action("R")
    def action_do_X(self) -> None: self._run_action("X")

    @work
    async def action_launch(self) -> None:
        harness = self._selected_harness
        if not harness:
            # Don't just log — take the newcomer to where the choice lives, and
            # focus the table so the next keystroke picks a harness.
            self.query_one("#results", RichLog).write(
                "[yellow]no harness selected — opening Harnesses; pick one, then press l[/]"
            )
            self._selected = "harnesses"
            await self.show_panel("harnesses")
            table = self.query_one("#data-table", DataTable)
            if table.display:
                table.focus()
            return
        # Source the gate's grade from the single classify oracle. Launch hands
        # off the TTY via execvp so it can't ride _run_argv, but its gate must
        # not diverge from the oracle either (classify → BILLABLE for launch).
        grade = classify(["harness", "launch", harness])
        ok = await self.push_screen_wait(
            ConfirmModal(
                f"launch {harness}: cloud-backed tiers make billable provider requests.",
                title=f"Confirm launch -> {harness}",
                grade=grade,
            )
        )
        if not ok:
            return
        self.exit(result=("launch", [harness]))

    @work
    async def action_effort(self) -> None:
        if self._selected == "models" and self._selected_model:
            target, level = self._selected_model, "model"
            allowed = await asyncio.to_thread(self.client.model_reasoning_allowed, target)
        elif self._selected == "harnesses" and self._selected_harness:
            target, level = self._selected_harness, "harness"
            allowed = await asyncio.to_thread(self.client.harness_reasoning_allowed, target)
        else:
            self.query_one("#results", RichLog).write(
                "[yellow]select a model or harness row first, then press e[/]"
            )
            return
        from .effort_modal import EffortSelector
        choice = await self.push_screen_wait(EffortSelector(allowed, target))
        if choice is None:
            return
        if choice == "unset":
            argv = [level, "reasoning", "unset", target]
        else:
            argv = [level, "reasoning", "set", target, choice]
        await self._run_argv(argv, f"{level} reasoning {target}")

    @work
    async def action_key(self) -> None:
        if self._selected != "keys":
            self.query_one("#results", RichLog).write(
                "[yellow]open the Keys panel first, then press k[/]"
            )
            return
        providers = list((await asyncio.to_thread(self.client.key_status)).keys())
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
