"""fabric — read-only control-plane TUI over ai-litellm."""
from __future__ import annotations
from pathlib import Path
from textual.app import App, ComposeResult
from textual.containers import Horizontal
from textual.widgets import Header, Footer, Tree, Static, RichLog
from textual import work
from .client import FabricClient
from .safety import ACTIONS, SAFE
from .actions import ActionRunner
from .modal import ConfirmModal

CONCEPTS = [
    ("proxy", "Proxy"),
    ("harnesses", "Harnesses"),
    ("models", "Models / Routes"),
    ("runtimes", "Runtimes"),
    ("budget", "Budget & Policy"),
    ("keys", "Keys"),
]


class FabricApp(App):
    CSS_PATH = Path(__file__).parent / "app.tcss"
    TITLE = "ai-litellm fabric"
    BINDINGS = (
        [("q", "quit", "Quit"), ("r", "refresh", "Refresh")]
        + [(a.key, f"do_{a.key}", a.label) for a in ACTIONS]
    )

    def __init__(self, client: FabricClient | None = None, runner: ActionRunner | None = None):
        super().__init__()
        self.client = client or FabricClient()
        self.runner = runner or ActionRunner()
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
        yield RichLog(id="results", highlight=False, markup=True)
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
        dot = {"ok": "[green]o[/]", "unreachable": "[red]x[/]"}.get(health, "[yellow]?[/]")
        badge = "[yellow]STALE -> sync[/]" if cur == "stale" else f"[dim]{cur}[/]"
        self.query_one("#status", Static).update(f"{dot} proxy: {health}   config: {badge}   {url}")

    def show_panel(self, node_id: str) -> None:
        content = self.query_one("#content", Static)
        if node_id == "proxy":
            s = self.client.proxy_status()
            lines = [f"{k}: {v}" for k, v in s.items()] or ["proxy not running — start it"]
            content.update("\n".join(lines))
        elif node_id == "models":
            rows = self.client.model_limits() or self.client.model_list()
            content.update(_table_text(rows) or "no models / routes (is the proxy synced?)")
        elif node_id == "harnesses":
            content.update(_table_text(self.client.harness_list()) or "no harnesses")
        elif node_id == "runtimes":
            content.update(_table_text(self.client.runtime_status()) or "no runtimes")
        elif node_id == "budget":
            content.update(_table_text(self.client.reasoning_matrix()) or "no reasoning matrix")
        elif node_id == "keys":
            k = self.client.key_status()
            content.update("\n".join(f"{name}: {info.get('source','?')}" for name, info in k.items()) or "no keys")
        else:
            content.update("")

    # --- action helpers ---

    def _action_by_key(self, key: str):
        for a in ACTIONS:
            if a.key == key:
                return a
        return None

    @work
    async def _run_action(self, key: str) -> None:
        """Run an action; @work provides the worker context needed by push_screen_wait."""
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

    # Per-key action methods (explicit, not metaprogrammed); @work makes _run_action sync-callable
    def action_do_s(self) -> None: self._run_action("s")
    def action_do_R(self) -> None: self._run_action("R")
    def action_do_S(self) -> None: self._run_action("S")
    def action_do_x(self) -> None: self._run_action("x")
    def action_do_d(self) -> None: self._run_action("d")


def _table_text(rows: list) -> str:
    if not rows:
        return ""
    cols = list(rows[0].keys())
    head = "  ".join(f"{c:<18}" for c in cols)
    body = "\n".join("  ".join(f"{str(r.get(c,'')):<18}" for c in cols) for r in rows)
    return head + "\n" + body
