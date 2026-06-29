"""fabric — read-only control-plane TUI over ai-litellm."""
from __future__ import annotations
import asyncio
from pathlib import Path
from rich.text import Text
from textual.app import App, ComposeResult
from textual.containers import Horizontal, Vertical
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
    ("router", "Router"),
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
    "chosen": "Chosen",
    "billable": "Billable",
    "effectiveInput": "Effective In",
    "reasons": "Reasons",
    "risks": "Risks",
}

DEFAULT_ROUTER_INTENT = {
    "estimated": 1000,
    "preferred_harness": "",
    "preferred_model": "",
    "allow_billable": False,
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
    if key == "billable":
        billable = value is True or str(value).strip().lower() in ("true", "yes", "1")
        return Text("yes" if billable else "no", style=_BAD if billable else _OK)
    if key == "local":
        local = value is True or str(value).strip().lower() in ("true", "yes", "1")
        return Text("yes" if local else "no", style=_OK if local else "dim")
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
    ENABLE_COMMAND_PALETTE = False  # reserve ':' for this app's curated CommandPalette
    BINDINGS = (
        [("q", "quit", "Quit"), ("r", "refresh", "Refresh"), ("l", "launch", "Launch"),
         ("p", "router_plan", "Router plan"), ("v", "router_explain", "Router explain"),
         ("t", "router_dry_run", "Router dry-run"), ("E", "router_execute", "Router execute"),
         ("e", "effort", "Reasoning"), ("k", "key", "Set key"), ("m", "map", "Mapping"),
         ("question_mark", "help", "Help"), ("colon", "palette", "Commands")]
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
        if node_id == "router":
            items.append(FooterItem("p", "plan", SAFE, False))
            items.append(FooterItem("v", "explain", SAFE, False))
            items.append(FooterItem("t", "dry-run", SAFE, False))
            items.append(FooterItem("E", "execute", BILLABLE, True))
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
        self._selected_router_intent: dict | None = None
        self._selected_router_route: dict | None = None
        self._router_row_intents: dict[str, dict] = {}
        self._router_row_routes: dict[str, dict] = {}
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
            with Vertical(id="panel"):
                note = Static("", id="panel-note")
                note.display = False
                yield note
                detail = Static("", id="panel-detail")
                detail.display = False
                yield detail
                yield Static("", id="content")
                # One reusable table for every wide tabular view (harnesses, models,
                # runtimes, budget). DataTable sizes columns to content and scrolls,
                # so rows never wrap the way fixed-width text columns did.
                table: DataTable = DataTable(id="data-table", cursor_type="row", zebra_stripes=True)
                table.display = False  # shown only on tabular panels
                yield table
        results = RichLog(id="results", highlight=False, markup=True)
        results.display = False
        yield results
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
            if node_id != "router":
                self.query_one("#panel-note", Static).display = False
                self.query_one("#panel-detail", Static).display = False
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
        if self._selected == "router":
            if self._selected_router_route:
                route = self._selected_router_route
                billable = " [red]BILLABLE[/]" if route.get("billable") else " [green]local/no-billable[/]"
                launch = f"[dim]route ->[/] {route.get('harness','-')} {route.get('model','-')}{billable}"
            else:
                launch = "[dim]route ->[/] [yellow]no candidate[/]"
        elif self._selected_harness:
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
        "router": "no router candidates",
        "harnesses": "no harnesses",
        "models": "no models / routes (is the proxy synced?)",
        "runtimes": "no runtimes",
        "budget": "no reasoning matrix",
    }

    async def show_panel(self, node_id: str) -> None:
        content = self.query_one("#content", Static)
        table = self.query_one("#data-table", DataTable)
        note = self.query_one("#panel-note", Static)
        detail = self.query_one("#panel-detail", Static)
        # Set the panel title to the human label for this concept node.
        title = next((lbl for nid, lbl in CONCEPTS if nid == node_id), node_id)
        content.border_title = title
        table.border_title = title
        note.display = False
        detail.display = False
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
        elif node_id == "router":
            payload = await asyncio.to_thread(
                self.client.router_plan,
                self._router_args(DEFAULT_ROUTER_INTENT),
            )
            self._show_router_payload(payload, DEFAULT_ROUTER_INTENT)
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

    @staticmethod
    def _router_args(intent: dict) -> list[str]:
        args = ["--estimated-input-tokens", str(intent.get("estimated", 1000))]
        args.append("--allow-billable" if intent.get("allow_billable") else "--no-billable")
        if intent.get("preferred_harness"):
            args += ["--preferred-harness", intent["preferred_harness"]]
        if intent.get("preferred_model"):
            args += ["--preferred-model", intent["preferred_model"]]
        return args

    @staticmethod
    def _router_intent_for_route(base_intent: dict, route: dict) -> dict:
        intent = dict(base_intent or DEFAULT_ROUTER_INTENT)
        intent["preferred_harness"] = str(route.get("harness") or "")
        intent["preferred_model"] = str(route.get("model") or route.get("sourceModel") or "")
        # If a billable route is visible, it came from an allow-billable plan.
        # Preserve that route when executing from the highlighted row.
        intent["allow_billable"] = bool(intent.get("allow_billable") or route.get("billable"))
        return intent

    @staticmethod
    def _router_note(intent: dict, route: dict | None = None) -> str:
        mode = "allow-billable" if intent.get("allow_billable") else "no-billable"
        parts = [f"intent: {mode}", f"estimated input {intent.get('estimated', 1000)}"]
        if intent.get("preferred_harness"):
            parts.append(f"harness {intent['preferred_harness']}")
        if intent.get("preferred_model"):
            parts.append(f"model {intent['preferred_model']}")
        if route:
            billable = "billable" if route.get("billable") else "local/no-billable"
            parts.append(f"selected {route.get('harness','-')} {route.get('model','-')} ({billable})")
        return "   ".join(parts)

    @staticmethod
    def _router_detail(route: dict | None) -> str:
        if not route:
            return ""
        reasons = [str(r) for r in route.get("reasons") or [] if str(r)]
        risks = [str(r) for r in route.get("risks") or [] if str(r)]
        why = " / ".join(reasons[:2]) if reasons else "-"
        risk = " / ".join(risks[:2]) if risks else "none"
        return f"why: {why}\nrisks: {risk}"

    @staticmethod
    def _router_rows(payload: dict, intent: dict) -> list:
        selected = payload.get("selected") or {}
        candidates = list(payload.get("candidates") or [])
        if selected and not candidates:
            candidates = [selected]
        rows = []
        for c in candidates:
            is_selected = (
                selected
                and c.get("harness") == selected.get("harness")
                and c.get("model") == selected.get("model")
                and c.get("sourceModel") == selected.get("sourceModel")
            )
            row_key = ":".join(str(c.get(k) or "") for k in ("harness", "model", "provider", "sourceModel"))
            rows.append({
                "_rowKey": row_key,
                "_route": c,
                "_intent": FabricApp._router_intent_for_route(intent, c),
                "chosen": "*" if is_selected else "",
                "harness": c.get("harness"),
                "model": c.get("model"),
                "provider": c.get("provider"),
                "local": c.get("local"),
                "billable": c.get("billable"),
                "effectiveInput": c.get("effectiveInput"),
            })
        return rows

    def _select_router_row(self, row_key: str, fallback_intent: dict | None = None) -> None:
        intent = self._router_row_intents.get(row_key) or fallback_intent
        route = self._router_row_routes.get(row_key)
        if not intent:
            return
        self._selected_router_intent = intent
        self._selected_router_route = route
        self.query_one("#panel-note", Static).update(self._router_note(intent, route))
        detail = self.query_one("#panel-detail", Static)
        detail.update(self._router_detail(route))
        detail.display = bool(route)
        self.call_later(self.refresh_status)

    def _show_router_payload(self, payload: dict, intent: dict) -> None:
        table = self.query_one("#data-table", DataTable)
        content = self.query_one("#content", Static)
        note = self.query_one("#panel-note", Static)
        detail = self.query_one("#panel-detail", Static)
        rows = self._router_rows(payload, intent)
        self._router_row_intents = {}
        self._router_row_routes = {}
        if rows:
            row_keys = self._fill_table(table, rows, select=False)
            self._router_row_intents = {
                key: row.get("_intent", {}) for key, row in zip(row_keys, rows)
            }
            self._router_row_routes = {
                key: row.get("_route", {}) for key, row in zip(row_keys, rows)
            }
            first_key = row_keys[0]
            self._select_router_row(first_key, intent)
            note.display = True
            content.display = False
            table.display = True
            table.border_title = "Router"
        else:
            self._selected_router_intent = None
            self._selected_router_route = None
            note.update(self._router_note(intent))
            note.display = True
            detail.update("")
            detail.display = False
            table.display = False
            content.display = True
            content.border_title = "Router"
            content.update(self._EMPTY["router"])
            self.call_later(self.refresh_status)

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
        return str(row.get("_rowKey") or row.get("name") or row.get("model") or "")

    def _fill_table(self, table: DataTable, rows: list, *, select: bool) -> list[str]:
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
            return []
        cols = [c for c in rows[0].keys() if not c.startswith("_")]
        for c in cols:
            table.add_column(_label(c), key=c)
        row_keys: list[str] = []
        for i, r in enumerate(rows):
            row_key = f"{self._row_label(r)}#{i}"
            table.add_row(
                *[_cell(c, r.get(c)) for c in cols],
                key=row_key,
            )
            row_keys.append(row_key)
        if select and self._selected_harness is None:
            self._selected_harness = self._row_label(rows[0]) or None
            self.call_later(self.refresh_status)
        return row_keys

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
        if (
            event.data_table.id == "data-table"
            and self._selected == "router"
            and event.row_key is not None
            and event.row_key.value is not None
        ):
            self._select_router_row(str(event.row_key.value))

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        if (
            event.data_table.id == "data-table"
            and self._selected == "router"
            and event.row_key is not None
            and event.row_key.value is not None
        ):
            self._select_router_row(str(event.row_key.value))

    def _write_result(self, message: str) -> None:
        log = self.query_one("#results", RichLog)
        log.display = True
        log.write(message)

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
                self._write_result(f"[dim]cancelled: {name}[/]")
                return
        log = self.query_one("#results", RichLog)
        log.display = True
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
            self._write_result("[yellow]no harness selected — opening Harnesses; pick one, then press l[/]")
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
            self._write_result("[yellow]select a model or harness row first, then press e[/]")
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
            self._write_result("[yellow]open the Keys panel first, then press k[/]")
            return
        providers = list((await asyncio.to_thread(self.client.key_status)).keys())
        if not providers:
            self._write_result("[yellow]no key providers to set[/]")
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
            self._write_result("[yellow]select the claude or codex harness first, then press m[/]")
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
            self._write_result("[yellow]nothing to map[/]")
            return
        choice = await self.push_screen_wait(TierMapModal(rows, models, name_key=name_key, title=title))
        if choice is None:
            return
        name, model = choice
        await self._run_argv(argv0 + [name, model], label=f"map {self._selected_harness} {name}")

    def _router_panel_guard(self) -> bool:
        if self._selected != "router":
            self._write_result("[yellow]open the Router panel first, then use p/v/t/E[/]")
            return False
        return True

    @work
    async def action_router_plan(self) -> None:
        if not self._router_panel_guard():
            return
        from .router_modal import RouterIntentModal
        intent = await self.push_screen_wait(
            RouterIntentModal("router plan", initial=self._selected_router_intent)
        )
        if intent is None:
            return
        args = self._router_args(intent)
        payload = await asyncio.to_thread(self.client.router_plan, args)
        self._show_router_payload(payload, intent)
        selected = payload.get("selected") or {}
        self._write_result(f"[green]router plan[/]: {selected.get('harness','-')} {selected.get('model','-')}")

    @work
    async def action_router_explain(self) -> None:
        if not self._router_panel_guard():
            return
        from .router_modal import RouterIntentModal
        intent = await self.push_screen_wait(
            RouterIntentModal("router explain", initial=self._selected_router_intent)
        )
        if intent is None:
            return
        args = self._router_args(intent)
        payload = await asyncio.to_thread(self.client.router_explain, args)
        self._show_router_payload(payload, intent)
        selected = payload.get("selected") or {}
        rejected = payload.get("rejectedCount", 0)
        self._write_result(
            f"[green]router explain[/]: {selected.get('harness','-')} {selected.get('model','-')}  rejected={rejected}"
        )

    def _router_execute_argv(self, intent: dict, *, dry_run: bool) -> list[str]:
        argv = ["router", "execute", "--json", *self._router_args(intent), "--prompt-file", "-"]
        if dry_run:
            argv.append("--dry-run")
        elif intent.get("allow_billable"):
            argv.append("--confirm-billable")
        return argv

    @work
    async def action_router_dry_run(self) -> None:
        if not self._router_panel_guard():
            return
        from .router_modal import RouterIntentModal
        intent = await self.push_screen_wait(
            RouterIntentModal(
                "router dry-run",
                require_prompt=True,
                initial=self._selected_router_intent,
            )
        )
        if intent is None:
            return
        await self._run_argv(
            self._router_execute_argv(intent, dry_run=True),
            label="router dry-run",
            stdin_input=intent.get("prompt", ""),
        )

    @work
    async def action_router_execute(self) -> None:
        if not self._router_panel_guard():
            return
        from .router_modal import RouterIntentModal
        intent = await self.push_screen_wait(
            RouterIntentModal(
                "router execute",
                require_prompt=True,
                initial=self._selected_router_intent,
            )
        )
        if intent is None:
            return
        await self._run_argv(
            self._router_execute_argv(intent, dry_run=False),
            label="router execute",
            consequence="router execute runs the selected harness one-shot; cloud routes can make billable provider requests.",
            stdin_input=intent.get("prompt", ""),
        )
