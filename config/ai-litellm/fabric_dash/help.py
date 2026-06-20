"""`?` keymap overlay — makes every binding discoverable in one place."""
from __future__ import annotations
from textual.app import ComposeResult
from textual.screen import ModalScreen
from textual.widgets import Static

_KEYS = [
    ("q", "quit"), ("r", "refresh"), ("?", "this help"),
    (":", "command palette"), ("ctrl+p", "command palette"),
    ("s", "start proxy"), ("S", "sync (restart proxy)"),
    ("R", "restart proxy"), ("X", "stop proxy"), ("d", "doctor (full battery)"),
    ("l", "launch selected harness (billable)"),
    ("e", "set reasoning effort (model/harness)"),
    ("k", "set API key (masked)"),
    ("m", "remap claude tier (Harnesses)"),
    ("↑/↓", "move selection"), ("enter", "select / drill in"),
]


class HelpOverlay(ModalScreen):
    BINDINGS = [("question_mark", "dismiss", "Close"), ("escape", "dismiss", "Close"), ("q", "dismiss", "Close")]

    def compose(self) -> ComposeResult:
        lines = "\n".join(f"  [b]{k:<6}[/b]  {desc}" for k, desc in _KEYS)
        yield Static(f"[b]fabric — keys[/b]\n\n{lines}\n\n[dim]?/esc/q to close[/dim]", id="help-body")

    def action_dismiss(self) -> None:
        self.dismiss(None)
