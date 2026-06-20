"""Execute ai-litellm actions, streaming output. Never classifies — callers
gate via Action.needs_confirm + ConfirmModal first."""
from __future__ import annotations
import subprocess
from typing import Callable, Optional


def _default_spawn(argv: list) -> tuple:
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=600)
        lines = (p.stdout + p.stderr).splitlines()
        return (p.returncode, lines)
    except Exception as e:
        return (1, [f"error: {e}"])


class ActionRunner:
    def __init__(self, spawn: Optional[Callable] = None, binary: str = "ai-litellm"):
        self._spawn = spawn or _default_spawn
        self._bin = binary

    def run(self, argv: list, on_line: Callable[[str], None]) -> int:
        rc, lines = self._spawn([self._bin, *argv])
        for ln in lines:
            on_line(ln)
        return rc
