from __future__ import annotations
from textual.app import ComposeResult
from textual.screen import ModalScreen
from textual.containers import Vertical, Horizontal
from textual.widgets import Static, Button


class ConfirmModal(ModalScreen):
    BINDINGS = [("escape", "cancel", "Cancel"), ("enter", "confirm", "Confirm")]

    def __init__(self, consequence: str):
        super().__init__()
        self._consequence = consequence

    def compose(self) -> ComposeResult:
        with Vertical(id="confirm-box"):
            yield Static(f"! {self._consequence}", id="confirm-msg")
            with Horizontal():
                yield Button("Confirm", id="confirm-yes", variant="warning")
                yield Button("Cancel", id="confirm-no", variant="primary")

    def action_confirm(self) -> None:
        self.dismiss(True)

    def action_cancel(self) -> None:
        self.dismiss(False)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "confirm-yes")
