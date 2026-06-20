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
