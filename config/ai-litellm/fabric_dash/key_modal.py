"""Key-set picker — choose a provider, then enter the secret in a MASKED field.
Select-only: returns (provider, secret); the app pipes the secret to
`ai-litellm key set --keychain <provider>` via stdin (never argv/log)."""
from __future__ import annotations
from textual import on
from textual.app import ComposeResult
from textual.containers import Vertical
from textual.screen import ModalScreen
from textual.widgets import Input, Label, ListItem, ListView


class KeySetModal(ModalScreen):
    BINDINGS = [("escape", "cancel", "Cancel")]

    def __init__(self, providers: list[str]) -> None:
        super().__init__()
        self._providers = list(providers)
        self._provider: str | None = None

    def compose(self) -> ComposeResult:
        with Vertical(id="key-box"):
            yield Label("set API key — pick provider", id="key-title")
            yield ListView(id="key-list")
            secret = Input(placeholder="paste secret, enter to save", password=True, id="key-secret")
            secret.display = False
            yield secret

    def on_mount(self) -> None:
        lv = self.query_one("#key-list", ListView)
        for p in self._providers:
            lv.append(ListItem(Label(p), name=p))
        if self._providers:
            lv.index = 0
        lv.focus()

    @on(ListView.Selected, "#key-list")
    def _pick(self, event: ListView.Selected) -> None:
        self._provider = event.item.name if event.item is not None else None
        if self._provider is None:
            return
        self.query_one("#key-list", ListView).display = False
        self.query_one("#key-title", Label).update(f"set API key — {self._provider}")
        secret = self.query_one("#key-secret", Input)
        secret.display = True
        secret.focus()

    @on(Input.Submitted, "#key-secret")
    def _submit(self, event: Input.Submitted) -> None:
        if self._provider is not None and event.value:
            self.dismiss((self._provider, event.value))

    def action_cancel(self) -> None:
        self.dismiss(None)
