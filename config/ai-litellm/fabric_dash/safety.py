"""Classify ai-litellm actions by operational risk. Pure; no side effects."""
from __future__ import annotations
from collections import namedtuple

SAFE = "safe"
RESTART = "restart"
BILLABLE = "billable"
DESTRUCTIVE = "destructive"

Action = namedtuple("Action", "key label argv grade needs_confirm consequence")


def classify(argv: list) -> str:
    a = [x for x in argv if x]
    joined = " ".join(a)
    if a and a[0] == "uninstall":
        return DESTRUCTIVE
    if "probe" in a or joined.endswith("route check"):
        return BILLABLE
    if joined in ("sync", "proxy sync") or joined.startswith("proxy restart") \
            or joined.startswith("proxy stop") or a[:1] == ["sync"]:
        return RESTART
    return SAFE


ACTIONS = [
    Action("s", "sync", ["sync"], RESTART, True,
           "sync regenerates configs and restarts the proxy — this can interrupt active LiteLLM sessions."),
    Action("R", "restart", ["proxy", "restart"], RESTART, True,
           "restarting the proxy interrupts active LiteLLM-backed sessions."),
    Action("S", "start", ["proxy", "start"], SAFE, False, ""),
    Action("x", "stop", ["proxy", "stop"], RESTART, True,
           "stopping the proxy interrupts active LiteLLM-backed sessions."),
    Action("d", "doctor", ["proxy", "doctor"], SAFE, False, ""),
]
