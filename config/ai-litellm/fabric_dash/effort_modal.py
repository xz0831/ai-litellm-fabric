"""Reasoning-effort picker — lists the allowed efforts (+ 'unset') for the
selected model/harness and returns the choice. Select-only; the app runs the
chosen `reasoning set/unset` through the shared gated path."""
from __future__ import annotations
from textual import on
from textual.app import ComposeResult
from textual.containers import Vertical
from textual.screen import ModalScreen
from textual.widgets import Label, ListItem, ListView


class EffortSelector(ModalScreen):
    BINDINGS = [("escape", "cancel", "Cancel")]

    def __init__(self, efforts: list[str], target: str) -> None:
        super().__init__()
        self._choices = list(efforts) + ["unset"]
        self._target = target

    def compose(self) -> ComposeResult:
        with Vertical(id="effort-box"):
            yield Label(f"reasoning effort — {self._target}", id="effort-title")
            lv = ListView(id="effort-list")
            yield lv

    def on_mount(self) -> None:
        lv = self.query_one("#effort-list", ListView)
        for c in self._choices:
            lv.append(ListItem(Label(c), name=c))
        lv.index = 0
        lv.focus()

    @on(ListView.Selected, "#effort-list")
    def _picked(self, event: ListView.Selected) -> None:
        # event.item.name is set via ListItem(name=c) — verified in textual 8.2.7.
        # Fallback: index into self._choices if name is unavailable.
        name = event.item.name if event.item is not None else None
        if name is None and event.index is not None and 0 <= event.index < len(self._choices):
            name = self._choices[event.index]
        self.dismiss(name)

    def action_cancel(self) -> None:
        self.dismiss(None)
