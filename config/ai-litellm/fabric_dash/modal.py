from __future__ import annotations
from textual.app import ComposeResult
from textual.screen import ModalScreen
from textual.containers import Vertical, Horizontal
from textual.widgets import Static, Button

# Grades that interrupt active work — default focus to Cancel so a reflexive
# Enter can't fire a disruptive action. (mirrors safety.RESTART)
_GUARDED = {"restart", "destructive", "billable"}
# Note: "destructive" stays in the guard set so that if a destructive action is
# ever wired into ACTIONS, its modal is Cancel-first by default. No destructive
# action is currently surfaced, so its dedicated red styling was removed.


class ConfirmModal(ModalScreen):
    # No global enter->confirm: Enter activates the *focused* button instead,
    # and for guarded actions that button is Cancel.
    BINDINGS = [("escape", "cancel", "Cancel")]

    def __init__(self, consequence: str, title: str = "Confirm action", grade: str = "restart"):
        super().__init__()
        self._consequence = consequence
        self._title = title
        self._grade = (grade or "").lower()

    @property
    def _guarded(self) -> bool:
        return self._grade in _GUARDED

    def compose(self) -> ComposeResult:
        box = Vertical(id="confirm-box")
        with box:
            yield Static(self._title, id="confirm-title")
            yield Static(self._consequence, id="confirm-msg")
            with Horizontal(id="confirm-buttons"):
                # Cancel first for guarded grades so it reads (and tabs) as the default.
                if self._guarded:
                    yield Button("Cancel", id="confirm-no", variant="primary")
                    yield Button("Confirm", id="confirm-yes", variant="warning")
                else:
                    yield Button("Confirm", id="confirm-yes", variant="warning")
                    yield Button("Cancel", id="confirm-no", variant="primary")

    def on_mount(self) -> None:
        # Focus the safe choice for guarded actions; otherwise focus Confirm.
        target = "#confirm-no" if self._guarded else "#confirm-yes"
        self.query_one(target, Button).focus()

    def action_cancel(self) -> None:
        self.dismiss(False)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "confirm-yes")
