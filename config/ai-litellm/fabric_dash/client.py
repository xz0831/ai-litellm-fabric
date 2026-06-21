"""Read-only client over the `ai-litellm … --json` surface.

Never re-derives state; never runs mutating/billable commands. On any failure
returns an empty container so the TUI shows "empty", never a traceback.
"""
from __future__ import annotations
import json
import subprocess
from typing import Callable, Optional

Runner = Callable[[list], tuple]


def _default_runner(argv: list) -> tuple:
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=15)
        return (p.returncode, p.stdout)
    except Exception:
        return (1, "")


class FabricClient:
    def __init__(self, runner: Optional[Runner] = None, binary: str = "ai-litellm"):
        self._run = runner or _default_runner
        self._bin = binary

    def _json(self, *args: str):
        rc, out = self._run([self._bin, *args])
        if rc != 0:
            return None
        try:
            return json.loads(out)
        except Exception:
            return None

    def _obj(self, *args: str) -> dict:
        v = self._json(*args)
        return v if isinstance(v, dict) else {}

    def _arr(self, *args: str) -> list:
        v = self._json(*args)
        return v if isinstance(v, list) else []

    def proxy_status(self) -> dict: return self._obj("proxy", "status", "--json")
    def key_status(self) -> dict: return self._obj("key", "status", "--json")
    def model_list(self) -> list: return self._arr("model", "list", "--json")
    def model_limits(self, model: Optional[str] = None) -> list:
        return self._arr("model", "limits", model, "--json") if model else self._arr("model", "limits", "--json")
    def model_reasoning_allowed(self, model: str) -> list:
        return self._arr("model", "reasoning", "allowed", model, "--json")
    def runtime_status(self) -> list: return self._arr("runtime", "status", "--json")
    def reasoning_matrix(self) -> list: return self._arr("reasoning", "matrix", "--json")
    def harness_list(self) -> list: return self._arr("harness", "list", "--json")
    def harness_reasoning_allowed(self, name: str) -> list:
        return self._arr("harness", "reasoning", "allowed", name, "--json")
    def harness_aliases(self, name: str) -> list:
        return self._arr("harness", "alias", "get", name, "--json")
    def codex_facades(self) -> list:
        return self._arr("codex", "facade", "get", "--json")
