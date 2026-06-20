"""Color-graded action bar.

The stock textual Footer renders every keybinding in one flat color, so a
restart/stop/billable action is visually indistinguishable from a read-only
refresh. This footer reuses the status color system (green = safe, amber =
disruptive, red = billable/destructive) and separates the read-only group from
the mutating group with a divider, so the action bar encodes risk the same way
the panels do. It is a plain Static so its rendered text is trivially testable.
"""
from __future__ import annotations
from collections import namedtuple
from rich.text import Text
from textual.widgets import Static

# A footer entry: the key to press, its label, and a safety grade that picks the
# color. ``mutating`` splits the read-only group from the disruptive group.
FooterItem = namedtuple("FooterItem", "key label grade mutating")

# Grade → color, mirroring app.tcss .ok/.warn/.bad ($success/$warning/$error).
_GRADE_COLOR = {
    "safe": "green",
    "restart": "yellow",
    "billable": "red",
    "destructive": "red",
}
_NEUTRAL = "dim"  # quit: neither risky nor a status signal


def grade_color(grade: str) -> str:
    return _GRADE_COLOR.get((grade or "").lower(), _NEUTRAL)


class StatusFooter(Static):
    """Renders FooterItems as a single color-graded line."""

    def set_items(self, items: list[FooterItem]) -> None:
        self.update(self.build(items))

    @staticmethod
    def build(items: list[FooterItem]) -> Text:
        out = Text(no_wrap=True)
        prev_mutating = False
        first = True
        for it in items:
            if not first:
                # Divider between the read-only group and the mutating group.
                if it.mutating and not prev_mutating:
                    out.append("  │  ", style="dim")
                else:
                    out.append("  ")
            color = _NEUTRAL if it.key in ("q", "?") else grade_color(it.grade)
            out.append(f" {it.key} ", style=f"reverse {color}")
            out.append(" ")
            out.append(it.label, style=color)
            prev_mutating = it.mutating
            first = False
        return out
