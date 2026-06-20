"""Execute ai-litellm actions, streaming output. Never classifies — callers
gate via Action.needs_confirm + ConfirmModal first."""
from __future__ import annotations
import subprocess
from typing import Callable, Optional


def _default_spawn(argv: list, stdin_input: Optional[str] = None) -> tuple:
    try:
        p = subprocess.run(argv, input=stdin_input, capture_output=True, text=True, timeout=600)
        lines = (p.stdout + p.stderr).splitlines()
        return (p.returncode, lines)
    except Exception as e:
        return (1, [f"error: {e}"])


class ActionRunner:
    def __init__(self, spawn: Optional[Callable] = None, binary: str = "ai-litellm"):
        self._spawn = spawn or _default_spawn
        self._bin = binary

    def run(self, argv: list, on_line: Callable[[str], None], stdin_input: Optional[str] = None) -> int:
        # Call the 2-arg form ONLY when piping stdin, so existing 1-arg fake
        # spawns keep working. The secret (stdin_input) is passed to the child's
        # stdin and is never handed to on_line.
        if stdin_input is None:
            rc, lines = self._spawn([self._bin, *argv])
        else:
            rc, lines = self._spawn([self._bin, *argv], stdin_input)
        for ln in lines:
            on_line(ln)
        return rc
