"""Generic two-mode picker — pick a row by name_key, then a model_name. Select-only:
returns (name, model); the app runs the appropriate alias-set command.
Default params preserve the P4a TierMapModal(tiers, models) call unchanged."""
from __future__ import annotations
from textual import on
from textual.app import ComposeResult
from textual.containers import Vertical
from textual.screen import ModalScreen
from textual.widgets import Label, ListItem, ListView


class TierMapModal(ModalScreen):
    BINDINGS = [("escape", "cancel", "Cancel")]

    def __init__(self, rows: list[dict], models: list[str],
                 name_key: str = "tier",
                 title: str = "remap claude tier — pick row") -> None:
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

    @on(ListView.Selected, "#tier-list")
    def _select(self, event: ListView.Selected) -> None:
        if self._row is None:
            self._row = event.item.name if event.item is not None else None
            if self._row is None:
                return
            self.query_one("#tier-title", Label).update(f"remap {self._row} — pick model")
            lv = self.query_one("#tier-list", ListView)
            lv.clear()
            for m in self._models:
                lv.append(ListItem(Label(m), name=m))
            if self._models:
                lv.index = 0
        else:
            model = event.item.name if event.item is not None else None
            if model is not None:
                self.dismiss((self._row, model))

    def action_cancel(self) -> None:
        self.dismiss(None)
