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
    # harness launch makes billable provider requests; route it through the
    # oracle so the launch gate (app.action_launch) can't silently diverge.
    if a[:2] == ["harness", "launch"]:
        return BILLABLE
    # Billable probes: the `probe` verb token or a `--probe*` flag (covers
    # `route probe`, `reasoning probe`, and `proxy doctor --probe-routes`), and
    # `route check <model>` for any trailing model arg (endswith missed `route
    # check glm52`). Matched at verb/flag position, NOT as a free substring, so a
    # data arg like a model name containing "probe" can't false-trigger BILLABLE.
    if any(t == "probe" or t.startswith("--probe") for t in a) or a[:2] == ["route", "check"]:
        return BILLABLE
    if joined in ("sync", "proxy sync") or joined.startswith("proxy restart") \
            or joined.startswith("proxy stop") or a[:1] == ["sync"]:
        return RESTART
    return SAFE


# Keybinding convention (load-bearing safety affordance):
#   lowercase = safe / read-only      (s start, d doctor)
#   UPPERCASE = mutating / disruptive  (S sync, R restart, X stop)
# so a mistyped Shift always moves toward the *guarded* side (which is gated by
# a confirm modal), never silently fires a disruptive action. The old layout
# had s=sync (risky) one Shift from S=start (safe) and x=stop lowercase, so case
# did not map to risk — see safety.py history. order: safe group, then risky.
ACTIONS = [
    Action("s", "start", ["proxy", "start"], SAFE, False, ""),
    Action("d", "doctor", ["proxy", "doctor"], SAFE, False, ""),
    Action("S", "sync", ["sync"], RESTART, True,
           "sync regenerates configs and restarts the proxy — this can interrupt active LiteLLM sessions."),
    Action("R", "restart", ["proxy", "restart"], RESTART, True,
           "restarting the proxy interrupts active LiteLLM-backed sessions."),
    Action("X", "stop", ["proxy", "stop"], RESTART, True,
           "stopping the proxy interrupts active LiteLLM-backed sessions."),
]
