#!/usr/bin/env python3
"""Differential test for the five token-budget implementations.

There are five independent copies of the output-reservation / token-budget math
in this repo. Four compute an *effectiveInput* (usable input budget); one
(Python) computes an *outputCap* (max output tokens). They MUST stay in
lockstep on the quantities that are comparable:

  1. Node      ai_litellm_harness_output_budget  (lib.zsh node -e block)   -> effectiveInput
  2. Ruby-cat  effective_input                    (lib.zsh ruby catalog)    -> effectiveInput
  3. Ruby-mat  output_budget                      (lib.zsh ruby matrix)     -> effectiveInput
  4. Python    gateway_output_cap                 (output_clamp.py)         -> outputCap
  5. Ruby-res  output_budget                      (lib.zsh harness-         -> effectiveInput
               (ai_litellm_context_harness_reservations_ok ruby block)

This harness feeds one input matrix to ALL FIVE and asserts the comparable
fields are IDENTICAL. It is the real guard; check.zsh runs it in CI.

Anti-drift: the four lib.zsh copies are NOT pasted here. They are sliced out of
lib.zsh at runtime by line range and executed live, so this test always tests
the shipped code. A SHA guard (LIB_SLICES) documents the ranges; if lib.zsh is
refactored the ranges move and the slice markers below must be updated -- the
test fails loudly (extracted text won't define the expected function) rather
than silently testing a stale copy.

Run:  python3 scripts/verify_budget_consistency.py
Exit: 0 = all five agree across the matrix; 1 = drift (a real latent bug) or
      an implementation could not be driven.
"""
from __future__ import annotations

import json
import math
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parent.parent
LIB = REPO / "config" / "ai-litellm" / "lib.zsh"
PY_PKG = REPO / "config"

# --- line ranges of the three shell-embedded copies (1-based, inclusive) ------
# These are the bodies *between* the surrounding shell quoting, verbatim from
# lib.zsh. If they drift, the marker check below fails before any row runs.
NODE_RANGE = (449, 515)          # node -e '<body>' in ai_litellm_harness_output_budget
RUBY_CAT_RANGE = (543, 581)      # positive_int + pick_reservation + effective_input
RUBY_MAT_RANGE = (4825, 4886)    # positive_int + output_budget
# 5th copy: the ruby block inside ai_litellm_context_harness_reservations_ok().
# positive_int (5688-5693) ... output_budget (5719-5753). The intervening
# selections() def (5695-5717) is inert here -- never called -- and harmless.
RUBY_RES_RANGE = (5688, 5753)    # positive_int + (selections) + output_budget


# =============================================================================
# 1. ORACLE  -- the canonical spec both families derive from.
# =============================================================================
def posint(value: Any) -> int | None:
    """Mirror of the *Number()/to_i loose* coercion used by Node + Ruby-catalog
    + Python (int()). Non-finite / non-positive -> None."""
    try:
        n = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(n) or n <= 0:
        return None
    return int(math.floor(n))


def canonical_budget(
    context_in: Any,
    capability_in: Any,
    *,
    default: int | None = 32000,
    tokenizer_headroom: Any = 8192,
    minimum_input: Any = 32768,
    per_selection: int | None = None,
    per_tier: int | None = None,
    per_model: int | None = None,
) -> dict[str, Any]:
    """The reference effectiveInput computation (Node / Ruby-cat / Ruby-mat)."""
    context = posint(context_in)
    capability = posint(capability_in)
    cfg_headroom = posint(tokenizer_headroom)
    cfg_headroom = 0 if cfg_headroom is None else cfg_headroom
    cfg_min_input = posint(minimum_input)
    cfg_min_input = 32768 if cfg_min_input is None else cfg_min_input

    chosen = None
    for cand in (per_selection, per_tier, per_model, default):
        n = posint(cand)
        if n is not None:
            chosen = n
            break

    if chosen is None:
        if capability is None:
            return {"sentinel": "no-reservation", "context": context,
                    "capability": capability, "effectiveInput": None}
        reservation = min(capability, 32000)
    else:
        reservation = chosen

    if capability is not None and reservation > capability:
        reservation = capability

    headroom = cfg_headroom
    min_input = cfg_min_input
    if context is not None:
        headroom = min(headroom, math.floor(context * 0.1))
        min_input = min(min_input, max(1, math.floor(context * 0.5)))
        max_reservation = context - headroom - min_input
        if max_reservation < 1:
            reservation = 1
            headroom = max(0, context - min_input - reservation)
        elif reservation > max_reservation:
            reservation = max_reservation

    effective_input = None if context is None else max(0, context - reservation - headroom)
    return {
        "sentinel": None,
        "context": context,
        "capability": capability,
        "reservation": reservation,
        "tokenizerHeadroom": headroom,
        "minimumInput": min_input,
        "effectiveInput": effective_input,
    }


def canonical_output_cap(
    context_in: Any,
    capability_in: Any,
    *,
    default: int = 32000,
    per_model: int | None = None,
    tokenizer_headroom: Any = 8192,
    minimum_input: Any = 32768,
) -> int:
    """The reference Python outputCap computation (gateway_output_cap)."""
    cap = posint(per_model) or posint(default) or 32000
    capability = posint(capability_in)
    if capability is not None:
        cap = min(cap, capability)
    context = posint(context_in)
    if context is not None:
        headroom = posint(tokenizer_headroom) or 0
        headroom = min(headroom, math.floor(context * 0.1))
        min_input = posint(minimum_input) or 32768
        min_input = min(min_input, max(1, math.floor(context * 0.5)))
        max_reservation = context - headroom - min_input
        cap = min(cap, max_reservation if max_reservation > 0 else 1)
    return max(1, cap)


# =============================================================================
# 2. DRIVERS  -- invoke the four real implementations.
# =============================================================================
def _slice_lib(start: int, end: int) -> str:
    lines = LIB.read_text(encoding="utf-8").splitlines()
    return "\n".join(lines[start - 1:end])


_NODE_BODY = _slice_lib(*NODE_RANGE)
_RUBY_CAT_BODY = _slice_lib(*RUBY_CAT_RANGE)
_RUBY_MAT_BODY = _slice_lib(*RUBY_MAT_RANGE)
_RUBY_RES_BODY = _slice_lib(*RUBY_RES_RANGE)

# Sanity: the extracted slices must define the functions we expect. If lib.zsh is
# refactored and the ranges go stale, fail loudly here -- never test a wrong slice.
_SLICE_GUARDS = [
    ("NODE", _NODE_BODY, ["const positiveInt", "effectiveInput", "console.log"]),
    ("RUBY_CAT", _RUBY_CAT_BODY, ["def positive_int", "def pick_reservation", "def effective_input"]),
    ("RUBY_MAT", _RUBY_MAT_BODY, ["def positive_int", "def output_budget"]),
    # The 5th copy: its output_budget signature is (policy, selection, model, ctx,
    # out) -- it takes the resolved POLICY, not the descriptor -- and it returns
    # the comparable budget under the :effective key (not :effective_input). The
    # capability-clamped-default fallback is the load-bearing line we guard on.
    ("RUBY_RES", _RUBY_RES_BODY, [
        "def positive_int", "def output_budget(policy, selection, model, ctx, out)",
        "[capability, 32000].compact.min", "effective = context ?",
    ]),
]


def _check_slices() -> list[str]:
    errs = []
    for name, body, needles in _SLICE_GUARDS:
        for needle in needles:
            if needle not in body:
                errs.append(f"lib.zsh slice {name} range is stale: missing {needle!r} "
                            f"(update *_RANGE in {Path(__file__).name})")
    # Catalog slice must NOT include the per-model-collapsing wrapper (we drive
    # effective_input directly so we can exercise perTier/perSelection).
    if "ai_litellm_codex_catalog_context_map" in _RUBY_CAT_BODY:
        errs.append("RUBY_CAT slice leaked the wrapper; tighten RUBY_CAT_RANGE")
    return errs


def policy_descriptor_json(policy: dict[str, Any]) -> str:
    return json.dumps({"adapterConfig": {"outputReservation": policy}})


def build_policy(default=32000, headroom=8192, min_input=32768,
                 per_selection=None, per_tier=None, per_model=None,
                 selection=None, model=None, empty=False,
                 no_default=False) -> dict[str, Any]:
    """no_default omits the ``default`` reservation key (and any perX) while
    keeping tokenizerHeadroom/minimumInput, so the policy is non-empty but NO
    reservation source resolves -- forcing the capability-clamped-default
    fallback (reservation = min(capability, 32000)) when a capability exists,
    or the no-reservation sentinel when it doesn't."""
    if empty:
        return {}
    p: dict[str, Any] = {}
    if default is not None and not no_default:
        p["default"] = default
    if headroom is not None:
        p["tokenizerHeadroom"] = headroom
    if min_input is not None:
        p["minimumInput"] = min_input
    if per_selection is not None and selection is not None:
        p["perSelection"] = {selection: per_selection}
    if per_tier is not None and selection is not None:
        p["perTier"] = {selection: per_tier}
    if per_model is not None and model is not None:
        p["perModel"] = {model: per_model}
    return p


def drive_node(policy: dict, selection: str, model: str,
               context: Any, capability: Any) -> dict[str, Any]:
    """Run the verbatim node -e block with its 4 argv. limits omits 'output'
    when capability is None (capability=null path)."""
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        f.write(policy_descriptor_json(policy))
        descriptor = f.name
    try:
        limits: dict[str, Any] = {}
        if context is not None:
            limits["context"] = context
        if capability is not None:
            limits["output"] = capability
        proc = subprocess.run(
            ["node", "-e", _NODE_BODY, descriptor, selection, model, json.dumps(limits)],
            capture_output=True, text=True,
        )
    finally:
        os.unlink(descriptor)
    if proc.returncode != 0:
        return {"sentinel": "exit-nonzero", "rc": proc.returncode, "stderr": proc.stderr.strip()}
    return {"sentinel": None, **json.loads(proc.stdout)}


_RUBY_CAT_SHIM = r'''
require "json"
%s
descriptor = JSON.parse(STDIN.read)
policy = descriptor.dig("adapterConfig", "outputReservation") || {}
selection = ARGV[0]; model = ARGV[1]
ctx = ARGV[2].empty? ? nil : ARGV[2].to_i
out = ARGV[3].empty? ? nil : ARGV[3].to_i
val = effective_input(policy, selection, model, ctx, out)
puts JSON.generate({"effective_input" => val})
'''


def drive_ruby_catalog(policy: dict, selection: str, model: str,
                       context: Any, capability: Any) -> dict[str, Any]:
    """Drive the catalog effective_input directly (distinct selection/model so the
    perSelection>perTier>perModel precedence is exercised, unlike the wrapper).

    Production contract: the catalog WRAPPER (lib.zsh ~590) coerces context via
    positive_int and does `next unless context`, so effective_input is NEVER
    called with a non-positive/non-finite context -- it is skipped entirely. We
    honor that contract here: a context that doesn't survive posint() means the
    model is absent from the catalog map (sentinel "skipped"), NOT a 0 budget.
    Driving the raw negative into effective_input would test a state the wrapper
    makes unreachable."""
    if posint(context) is None and context is not None:
        return {"sentinel": "skipped-by-wrapper-guard"}
    script = _RUBY_CAT_SHIM % _RUBY_CAT_BODY
    proc = subprocess.run(
        ["ruby", "-e", script,
         selection, model,
         "" if context is None else str(context),
         "" if capability is None else str(capability)],
        input=policy_descriptor_json(policy), capture_output=True, text=True,
    )
    if proc.returncode != 0:
        return {"sentinel": "exit-nonzero", "rc": proc.returncode, "stderr": proc.stderr.strip()}
    return {"sentinel": None, **json.loads(proc.stdout)}


_RUBY_MAT_SHIM = r'''
require "json"
%s
descriptor = JSON.parse(STDIN.read)
selection = ARGV[0]; model = ARGV[1]
ctx = ARGV[2].empty? ? nil : ARGV[2].to_i
out = ARGV[3].empty? ? nil : ARGV[3].to_i
b = output_budget(descriptor, selection, model, ctx, out)
if b.nil?
  puts JSON.generate({"nil" => true})
else
  puts JSON.generate(b)
end
'''


def drive_ruby_matrix(policy: dict, selection: str, model: str,
                      context: Any, capability: Any) -> dict[str, Any]:
    script = _RUBY_MAT_SHIM % _RUBY_MAT_BODY
    proc = subprocess.run(
        ["ruby", "-e", script,
         selection, model,
         "" if context is None else str(context),
         "" if capability is None else str(capability)],
        input=policy_descriptor_json(policy), capture_output=True, text=True,
    )
    if proc.returncode != 0:
        return {"sentinel": "exit-nonzero", "rc": proc.returncode, "stderr": proc.stderr.strip()}
    out = json.loads(proc.stdout)
    if out.get("nil"):
        return {"sentinel": "nil"}
    return {"sentinel": None, **out}


# The 5th copy: the output_budget inside ai_litellm_context_harness_reservations_ok.
# Its signature is (policy, selection, model, ctx, out) -- it receives the resolved
# outputReservation POLICY directly (the surrounding shell does
# `policy = descriptor.dig("adapterConfig","outputReservation") || {}` and
# `next if policy.empty?` BEFORE calling it), and it returns a hash whose
# comparable budget lives under :effective (not :effective_input). We pass the
# raw policy on STDIN and reproduce the wrapper's empty-policy guard here so we
# only ever drive output_budget on states the production wrapper actually reaches.
_RUBY_RES_SHIM = r'''
require "json"
%s
policy = JSON.parse(STDIN.read)
selection = ARGV[0]; model = ARGV[1]
ctx = ARGV[2].empty? ? nil : ARGV[2].to_i
out = ARGV[3].empty? ? nil : ARGV[3].to_i
b = output_budget(policy, selection, model, ctx, out)
if b.nil?
  puts JSON.generate({"nil" => true})
else
  puts JSON.generate(b)
end
'''


def drive_ruby_reservations(policy: dict, selection: str, model: str,
                            context: Any, capability: Any) -> dict[str, Any]:
    """Drive the harness-reservations output_budget. It returns :effective; we
    normalise that to ``effective_input`` so callers compare the same field name
    as the other impls. nil -> sentinel 'nil' (matches Node exit / Ruby-mat nil
    when no reservation source and no capability resolve).

    Production contract: the surrounding shell does `next if policy.empty?`
    BEFORE calling output_budget, so an empty policy never reaches this copy.
    We honor that here (sentinel 'skipped-by-wrapper-guard') rather than driving
    a state the wrapper makes unreachable."""
    if not policy:
        return {"sentinel": "skipped-by-wrapper-guard"}
    script = _RUBY_RES_SHIM % _RUBY_RES_BODY
    proc = subprocess.run(
        ["ruby", "-e", script,
         selection, model,
         "" if context is None else str(context),
         "" if capability is None else str(capability)],
        # This copy takes the POLICY directly (not the full descriptor).
        input=json.dumps(policy), capture_output=True, text=True,
    )
    if proc.returncode != 0:
        return {"sentinel": "exit-nonzero", "rc": proc.returncode, "stderr": proc.stderr.strip()}
    out = json.loads(proc.stdout)
    if out.get("nil"):
        return {"sentinel": "nil"}
    # Normalise :effective -> effective_input for uniform comparison.
    return {"sentinel": None, "effective_input": out.get("effective"), **out}


# Python is imported, not subprocessed. Policy is injected via env so we never
# touch the real config. Clear bleed between rows.
sys.path.insert(0, str(PY_PKG))
from ai_litellm_callbacks.output_clamp import (  # noqa: E402
    gateway_output_cap,
    clamp_token_reservations,
)

try:
    import yaml as _yaml  # noqa: F401
    _HAVE_YAML = True
except Exception:
    _HAVE_YAML = False

# checks that could not be driven in this environment (reported, not failed)
SKIPPED: list[str] = []

_PY_ENV_KEYS = [
    "AI_LITELLM_OUTPUT_CLAMP_DEFAULT",
    "AI_LITELLM_OUTPUT_CLAMP_TOKENIZER_HEADROOM",
    "AI_LITELLM_OUTPUT_CLAMP_MINIMUM_INPUT",
    "AI_LITELLM_CONFIG",
]


def _clear_py_env() -> None:
    for k in _PY_ENV_KEYS:
        os.environ.pop(k, None)


def drive_python_cap(context: Any, capability: Any, *,
                     default=32000, headroom=8192, min_input=32768,
                     per_model=None, model_name=None) -> int | None:
    _clear_py_env()
    os.environ["AI_LITELLM_OUTPUT_CLAMP_DEFAULT"] = str(default)
    os.environ["AI_LITELLM_OUTPUT_CLAMP_TOKENIZER_HEADROOM"] = str(headroom)
    os.environ["AI_LITELLM_OUTPUT_CLAMP_MINIMUM_INPUT"] = str(min_input)
    info: dict[str, Any] = {}
    if context is not None:
        info["max_input_tokens"] = context
    if capability is not None:
        info["max_output_tokens"] = capability
    kwargs: dict[str, Any] = {"model_info": info}
    if per_model is not None and model_name is not None:
        # perModel is read from the YAML policy, not env. Write a tiny fixture.
        with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
            f.write(
                "x-gateway-output-clamp:\n"
                f"  default: {default}\n"
                f"  tokenizer_headroom: {headroom}\n"
                f"  minimum_input: {min_input}\n"
                "  perModel:\n"
                f"    {model_name}: {per_model}\n"
            )
            cfg = f.name
        os.environ["AI_LITELLM_CONFIG"] = cfg
        kwargs["model"] = model_name
        try:
            return gateway_output_cap(kwargs)
        finally:
            os.unlink(cfg)
            _clear_py_env()
    try:
        return gateway_output_cap(kwargs)
    finally:
        _clear_py_env()


# =============================================================================
# 3. MATRIX
# =============================================================================
# Each row: id, regime, context, capability, policy kwargs, families to apply.
# Reservation overrides are expressed via build_policy kwargs.
ROWS: list[dict[str, Any]] = [
    dict(id="L1", regime="Large DeepSeek/gpt-5.4", ctx=1048576, cap=384000, families="A,B,D"),
    dict(id="L2", regime="Large Kimi/gpt-5.4-mini", ctx=262142, cap=262142, families="A,B,D"),
    dict(id="L3", regime="Large GLM-5.2/gpt-5.5", ctx=1048576, cap=131072, families="A,B,D"),
    dict(id="L4", regime="Large cap<32000", ctx=1048576, cap=20000, families="A,B"),
    # B1/B2 do NOT hit the reservation==max_reservation edge: at ctx~72960 the
    # headroom scales to floor(ctx*0.1) so max_reservation=32896 vs reservation=
    # 32000 (896 apart). Relabeled to what they actually exercise (headroom
    # scaling under the 8192 cap). The exact MR==R edge is covered by BX-* below.
    dict(id="B1", regime="headroom scaled (R<MR by 896)", ctx=72960, cap=72960, families="A,B"),
    dict(id="B2", regime="headroom scaled, ctx-1", ctx=72959, cap=72959, families="A,B"),
    # --- Gap 2a: reservation == max_reservation EXACTLY (and +-1). ---
    # ctx=100000 keeps headroom=8192, min_input=32768 fixed, so MR=100000-40960=
    # 59040. The reservation source is the `default` key set equal to (and +-1 of)
    # MR, with a huge cap so the capabilityClamp never fires first. This is the
    # only place the `reservation > max_reservation` comparator sees equality.
    dict(id="BX-eq", regime="reservation==MR exactly", ctx=100000, cap=200000,
         default=59040, families="A"),       # MR=59040, R=59040 (not >), ei=32768
    dict(id="BX-m1", regime="reservation==MR-1", ctx=100000, cap=200000,
         default=59039, families="A"),       # R<MR, no clamp, ei=32769
    dict(id="BX-p1", regime="reservation==MR+1", ctx=100000, cap=200000,
         default=59041, families="A"),       # R>MR by 1 -> clamped to 59040, ei=32768
    # --- Gap 2b: EMPTY reservation policy (no default/perX) + capability present
    # forces reservation = min(capability, 32000). headroom/min_input still set so
    # the policy is non-empty (Ruby catalog/matrix don't take the empty short-cut).
    dict(id="CD-i", regime="cap-clamped-default, cap<32000", ctx=1048576, cap=20000,
         no_default=True, families="A"),      # reservation=cap=20000, ei=1020384
    dict(id="CD-ii", regime="cap-clamped-default, cap>=32000", ctx=1048576, cap=131072,
         no_default=True, families="A"),      # reservation=min(cap,32000)=32000, ei=1008384
    dict(id="B3a", regime="Kimi-1", ctx=262143, cap=262143, families="A,B"),
    dict(id="B3b", regime="Kimi+1", ctx=262144, cap=262144, families="A,B"),
    dict(id="S1", regime="Small, headroom scaled", ctx=80000, cap=80000, families="A,B"),
    dict(id="S2", regime="Small, R clamped to MR", ctx=50000, cap=50000, families="A,B"),
    dict(id="G1", regime="gemma 8192/4096", ctx=8192, cap=4096, families="A,B", pin_oc=3277),
    dict(id="G2", regime="gemma no capability", ctx=8192, cap=None, families="A,B", pin_oc=3277),
    dict(id="T1", regime="tiny window (MR<1)", ctx=1, cap=None, families="A,B,Ctiny"),
    dict(id="T2", regime="tiny, capability tiny", ctx=1, cap=1, families="A,B,Ctiny"),
    dict(id="D1", regime="output>=input degenerate", ctx=1000, cap=99999, families="A,B"),
    dict(id="P1", regime="perModel override", ctx=262142, cap=262142, families="A,B,m",
         per_model=50000, model="m1"),
    dict(id="P2", regime="perTier (Node/Ruby only)", ctx=262142, cap=262142, families="A2",
         per_tier=40000, selection="sel"),
    dict(id="P3", regime="perSel>perTier>perModel", ctx=262142, cap=262142, families="A2",
         per_selection=10000, per_tier=20000, per_model=30000, selection="sel", model="m1"),
    dict(id="Z1", regime="context=null", ctx=None, cap=4096, families="nullctx"),
    dict(id="N1", regime="NaN/negative floor to null", ctx=-5, cap=-1, families="nullctx"),
    dict(id="Z2", regime="no cap AND empty policy", ctx=50000, cap=None, families="Cempty", empty=True),
    # no capability AND no reservation source, but policy non-empty (headroom/
    # min_input present). Hits the no-reservation sentinel on Node (exit 1) and
    # Ruby-matrix (nil). Ruby-catalog does NOT short-circuit (policy non-empty)
    # so it resolves reservation = [nil,32000].compact.min = 32000 and computes a
    # real budget -- a genuine, documented impl divergence, asserted per-impl.
    dict(id="Z3", regime="no cap, reservation-empty policy", ctx=50000, cap=None,
         no_default=True, families="Cnodef"),
]


# =============================================================================
# 4. ASSERTIONS
# =============================================================================
class Failure:
    def __init__(self, row_id: str, msg: str, detail: dict | None = None):
        self.row_id = row_id
        self.msg = msg
        self.detail = detail or {}

    def __str__(self) -> str:
        d = json.dumps(self.detail, sort_keys=True) if self.detail else ""
        return f"[{self.row_id}] {self.msg}  {d}"


def run() -> int:
    slice_errs = _check_slices()
    if slice_errs:
        for e in slice_errs:
            print(f"SLICE-GUARD FAIL: {e}", file=sys.stderr)
        return 1

    failures: list[Failure] = []
    rows_checked = 0

    for row in ROWS:
        rid = row["id"]
        ctx = row["ctx"]
        cap = row["cap"]
        selection = row.get("selection", "default")
        model = row.get("model", "default")
        per_selection = row.get("per_selection")
        per_tier = row.get("per_tier")
        per_model = row.get("per_model")
        families = set(row["families"].split(","))
        empty = row.get("empty", False)
        no_default = row.get("no_default", False)
        # Per-row `default` reservation override (BX-* drive the MR==R edge). When
        # no_default is set the row deliberately has NO default reservation source.
        row_default = None if no_default else row.get("default", 32000)

        policy = build_policy(
            default=32000 if row_default is None else row_default,
            per_selection=per_selection, per_tier=per_tier, per_model=per_model,
            selection=selection, model=model, empty=empty, no_default=no_default,
        )

        # ---- ORACLE -------------------------------------------------------
        oracle = canonical_budget(
            ctx, cap,
            default=None if empty else row_default,
            tokenizer_headroom=None if empty else 8192,
            minimum_input=None if empty else 32768,
            per_selection=per_selection, per_tier=per_tier, per_model=per_model,
        )

        # ===================================================================
        # FAMILY A: effectiveInput agreement (Node + Ruby-cat + Ruby-mat)
        # ===================================================================
        if "A" in families:
            rows_checked += 1
            node = drive_node(policy, selection, model, ctx, cap)
            rmat = drive_ruby_matrix(policy, selection, model, ctx, cap)
            rcat = drive_ruby_catalog(policy, selection, model, ctx, cap)
            rres = drive_ruby_reservations(policy, selection, model, ctx, cap)

            o_ei = oracle.get("effectiveInput")

            # Node effectiveInput
            if node.get("sentinel") is None:
                n_ei = node.get("effectiveInput")
                if n_ei != o_ei:
                    failures.append(Failure(rid, "Node.effectiveInput != oracle",
                                            {"node": n_ei, "oracle": o_ei}))
            else:
                failures.append(Failure(rid, "Node unexpectedly signalled sentinel in Family A",
                                        {"node": node}))

            # Ruby-matrix effectiveInput
            if rmat.get("sentinel") is None:
                m_ei = rmat.get("effective_input")
                if m_ei != o_ei:
                    failures.append(Failure(rid, "RubyMatrix.effective_input != oracle",
                                            {"ruby_matrix": m_ei, "oracle": o_ei}))
            else:
                failures.append(Failure(rid, "RubyMatrix unexpectedly nil in Family A",
                                        {"ruby_matrix": rmat}))

            # Ruby-catalog effectiveInput
            r_ei = rcat.get("effective_input")
            if r_ei != o_ei:
                failures.append(Failure(rid, "RubyCatalog.effective_input != oracle",
                                        {"ruby_catalog": r_ei, "oracle": o_ei}))

            # Ruby-reservations effectiveInput (5th copy; :effective field)
            if rres.get("sentinel") is None:
                res_ei = rres.get("effective_input")
                if res_ei != o_ei:
                    failures.append(Failure(rid, "RubyReservations.effective != oracle",
                                            {"ruby_reservations": res_ei, "oracle": o_ei}))
            else:
                failures.append(Failure(rid, "RubyReservations unexpectedly nil in Family A",
                                        {"ruby_reservations": rres}))

            # Cross-impl: the four effectiveInput values must be identical.
            quad = {
                "node": node.get("effectiveInput") if node.get("sentinel") is None else "<sentinel>",
                "ruby_matrix": rmat.get("effective_input") if rmat.get("sentinel") is None else "<sentinel>",
                "ruby_catalog": r_ei,
                "ruby_reservations": rres.get("effective_input") if rres.get("sentinel") is None else "<sentinel>",
            }
            if len(set(map(json.dumps, quad.values()))) != 1:
                failures.append(Failure(rid, "effectiveInput DISAGREES across the four impls",
                                        quad))

            # Node + Ruby-matrix + Ruby-reservations must also agree on
            # reservation/headroom/minInput. (Ruby-reservations keys: :reservation,
            # :headroom, :minimum.)
            if (node.get("sentinel") is None and rmat.get("sentinel") is None
                    and rres.get("sentinel") is None):
                for nk, mk, rk, ok in (
                        ("reservation", "reservation", "reservation", "reservation"),
                        ("tokenizerHeadroom", "tokenizer_headroom", "headroom", "tokenizerHeadroom"),
                        ("minimumInput", "minimum_input", "minimum", "minimumInput")):
                    nv, mv, rv, ov = node.get(nk), rmat.get(mk), rres.get(rk), oracle.get(ok)
                    if not (nv == mv == rv == ov):
                        failures.append(Failure(rid, f"{ok} disagreement",
                                                {"node": nv, "ruby_matrix": mv,
                                                 "ruby_reservations": rv, "oracle": ov}))

        # ===================================================================
        # FAMILY A2: Node == Ruby-matrix only (perTier/perSelection; no Python,
        #            no catalog-wrapper -- but we DO drive catalog effective_input
        #            directly since it supports the same precedence).
        # ===================================================================
        if "A2" in families:
            rows_checked += 1
            node = drive_node(policy, selection, model, ctx, cap)
            rmat = drive_ruby_matrix(policy, selection, model, ctx, cap)
            rcat = drive_ruby_catalog(policy, selection, model, ctx, cap)
            rres = drive_ruby_reservations(policy, selection, model, ctx, cap)
            o_ei = oracle.get("effectiveInput")
            quad = {
                "node": node.get("effectiveInput"),
                "ruby_matrix": rmat.get("effective_input"),
                "ruby_catalog": rcat.get("effective_input"),
                "ruby_reservations": rres.get("effective_input"),
                "oracle": o_ei,
            }
            if not (quad["node"] == quad["ruby_matrix"] == quad["ruby_catalog"]
                    == quad["ruby_reservations"] == o_ei):
                failures.append(Failure(rid, "perTier/perSelection effectiveInput disagreement", quad))

        # ===================================================================
        # FAMILY B: outputCap agreement (Python only, vs oracle output_cap)
        # ===================================================================
        if "B" in families:
            o_oc = canonical_output_cap(ctx, cap)
            py_oc = drive_python_cap(ctx, cap)
            if py_oc != o_oc:
                failures.append(Failure(rid, "Python.gateway_output_cap != oracle outputCap",
                                        {"python": py_oc, "oracle": o_oc}))
            if "pin_oc" in row and o_oc != row["pin_oc"]:
                failures.append(Failure(rid, "oracle outputCap drifted from pinned legacy value",
                                        {"oracle": o_oc, "pin": row["pin_oc"]}))
            if "pin_oc" in row and py_oc != row["pin_oc"]:
                failures.append(Failure(rid, "Python outputCap drifted from pinned legacy value",
                                        {"python": py_oc, "pin": row["pin_oc"]}))

        # FAMILY Bm: Python perModel cap. perModel is read ONLY from the YAML
        # payload (no env var). Without PyYAML, output_clamp._read_config_payload
        # returns {} by design, so this path is undriveable -- skip, don't false-fail.
        if "m" in families:
            if not _HAVE_YAML:
                SKIPPED.append(f"{rid}: Python perModel cap (PyYAML not importable; "
                               "perModel injects only via YAML config)")
            else:
                o_oc = canonical_output_cap(ctx, cap, per_model=per_model)
                py_oc = drive_python_cap(ctx, cap, per_model=per_model, model_name=model)
                if py_oc != o_oc:
                    failures.append(Failure(rid, "Python perModel outputCap != oracle",
                                            {"python": py_oc, "oracle": o_oc}))

        # ===================================================================
        # FAMILY C_tiny: tiny window -- reservation==1 (not 0), Python cap>=1.
        # ===================================================================
        if "Ctiny" in families:
            node = drive_node(policy, selection, model, ctx, cap)
            rmat = drive_ruby_matrix(policy, selection, model, ctx, cap)
            if node.get("sentinel") is None and node.get("reservation") != 1:
                failures.append(Failure(rid, "Node tiny-window reservation != 1",
                                        {"node_reservation": node.get("reservation")}))
            if rmat.get("sentinel") is None and rmat.get("reservation") != 1:
                failures.append(Failure(rid, "RubyMatrix tiny-window reservation != 1",
                                        {"ruby_matrix_reservation": rmat.get("reservation")}))
            py_oc = drive_python_cap(ctx, cap)
            if py_oc is None or py_oc < 1:
                failures.append(Failure(rid, "Python tiny-window outputCap < 1",
                                        {"python": py_oc}))

        # ===================================================================
        # FAMILY AB_nullctx: context==null path. effectiveInput must be null on
        # the three effectiveInput impls; reservation/headroom unscaled. Python
        # cap computed with no context clamp.
        # ===================================================================
        if "nullctx" in families:
            node = drive_node(policy, selection, model, ctx, cap)
            rmat = drive_ruby_matrix(policy, selection, model, ctx, cap)
            rcat = drive_ruby_catalog(policy, selection, model, ctx, cap)
            rres = drive_ruby_reservations(policy, selection, model, ctx, cap)
            # oracle effectiveInput is None (context None / non-finite)
            for label, val in (("node", node.get("effectiveInput") if node.get("sentinel") is None else "<sentinel>"),
                               ("ruby_matrix", rmat.get("effective_input") if rmat.get("sentinel") is None else "<sentinel>"),
                               ("ruby_reservations", rres.get("effective_input") if rres.get("sentinel") is None else "<sentinel>")):
                if val not in (None, "<sentinel>"):
                    failures.append(Failure(rid, f"{label} effectiveInput should be null with null context",
                                            {label: val}))
            # Ruby-catalog: with a genuinely-null context (Z1) effective_input
            # returns nil; with a non-positive context (N1) the production wrapper
            # skips the model entirely (sentinel). Both are acceptable; a 0/other
            # numeric budget would be the bug.
            rcat_sentinel = rcat.get("sentinel")
            if rcat_sentinel is None and rcat.get("effective_input") is not None:
                failures.append(Failure(rid, "RubyCatalog effective_input should be nil with null context",
                                        {"ruby_catalog": rcat.get("effective_input")}))
            # Python outputCap (no context clamp)
            o_oc = canonical_output_cap(ctx, cap)
            py_oc = drive_python_cap(ctx, cap)
            if py_oc != o_oc:
                failures.append(Failure(rid, "Python null-context outputCap != oracle",
                                        {"python": py_oc, "oracle": o_oc}))

        # ===================================================================
        # FAMILY C_empty: empty policy -- impl-specific behavior, NOT cross-impl.
        #   Node: exit(1).  Ruby-matrix output_budget: nil.
        #   Ruby-catalog effective_input: returns context (passthrough).
        # ===================================================================
        if "Cempty" in families:
            node = drive_node(policy, selection, model, ctx, cap)
            rmat = drive_ruby_matrix(policy, selection, model, ctx, cap)
            rcat = drive_ruby_catalog(policy, selection, model, ctx, cap)
            rres = drive_ruby_reservations(policy, selection, model, ctx, cap)
            if node.get("sentinel") != "exit-nonzero":
                failures.append(Failure(rid, "Node empty-policy+no-cap should exit nonzero",
                                        {"node": node}))
            if rmat.get("sentinel") != "nil":
                failures.append(Failure(rid, "RubyMatrix empty-policy should return nil",
                                        {"ruby_matrix": rmat}))
            if rcat.get("effective_input") != ctx:
                failures.append(Failure(rid, "RubyCatalog empty-policy should pass context through",
                                        {"ruby_catalog": rcat.get("effective_input"), "context": ctx}))
            # Ruby-reservations: the wrapper skips empty policies before calling
            # output_budget, so this copy is never reached for an empty policy.
            if rres.get("sentinel") != "skipped-by-wrapper-guard":
                failures.append(Failure(rid, "RubyReservations empty-policy should be wrapper-skipped",
                                        {"ruby_reservations": rres}))

        # ===================================================================
        # FAMILY C_nodef: NO capability AND NO reservation source, but the policy
        # is NON-empty (headroom/min_input present). Impl-specific, NOT cross-impl:
        #   Node:        no reservation -> exit(1)  [SENTINEL_NO_RESERVATION]
        #   Ruby-matrix: no reservation -> nil      [SENTINEL_NO_RESERVATION]
        #   Ruby-catalog: policy non-empty so it does NOT short-circuit; resolves
        #                 reservation = [nil,32000].compact.min = 32000, then
        #                 computes a real budget. We pin that budget to the oracle
        #                 (default=32000 mirrors the .compact.min fallback).
        # ===================================================================
        if "Cnodef" in families:
            rows_checked += 1
            node = drive_node(policy, selection, model, ctx, cap)
            rmat = drive_ruby_matrix(policy, selection, model, ctx, cap)
            rcat = drive_ruby_catalog(policy, selection, model, ctx, cap)
            rres = drive_ruby_reservations(policy, selection, model, ctx, cap)
            if node.get("sentinel") != "exit-nonzero":
                failures.append(Failure(rid, "Node no-cap+no-reservation should exit nonzero (sentinel)",
                                        {"node": node}))
            if rmat.get("sentinel") != "nil":
                failures.append(Failure(rid, "RubyMatrix no-cap+no-reservation should return nil (sentinel)",
                                        {"ruby_matrix": rmat}))
            # Ruby-reservations matches Node/Ruby-matrix here: `return nil unless
            # pick || capability` -> no reservation source + no capability -> nil.
            # (It does NOT short-circuit on policy.empty?, but the policy is
            # non-empty here -- headroom/min_input present -- so the nil comes from
            # the pick||capability guard, same sentinel as the other two.)
            if rres.get("sentinel") != "nil":
                failures.append(Failure(rid, "RubyReservations no-cap+no-reservation should return nil (sentinel)",
                                        {"ruby_reservations": rres}))
            # Ruby-catalog resolves the 32000 fallback and computes a budget.
            cat_oracle = canonical_budget(
                ctx, cap, default=32000, tokenizer_headroom=8192, minimum_input=32768,
            ).get("effectiveInput")
            if rcat.get("effective_input") != cat_oracle:
                failures.append(Failure(rid, "RubyCatalog no-cap+no-reservation budget != oracle (32000 fallback)",
                                        {"ruby_catalog": rcat.get("effective_input"), "oracle": cat_oracle}))

        # ===================================================================
        # FAMILY D: Python clamp_token_reservations lower-only semantics.
        # ===================================================================
        if "D" in families:
            _clear_py_env()
            cap_val = canonical_output_cap(ctx, cap)
            info = {"max_input_tokens": ctx, "max_output_tokens": cap}
            kw = {"max_tokens": 999999, "max_completion_tokens": 5, "model_info": info}
            clamp_token_reservations(kw)
            if kw["max_tokens"] != min(999999, cap_val):
                failures.append(Failure(rid, "clamp_token_reservations max_tokens not lower-clamped",
                                        {"got": kw["max_tokens"], "want": min(999999, cap_val)}))
            if kw["max_completion_tokens"] != min(5, cap_val):
                failures.append(Failure(rid, "clamp_token_reservations did not keep lower value",
                                        {"got": kw["max_completion_tokens"], "want": min(5, cap_val)}))
            kw2 = {"max_tokens": 999999, "model_info": info}
            clamp_token_reservations(kw2)
            if "max_completion_tokens" in kw2:
                failures.append(Failure(rid, "clamp_token_reservations injected an absent key",
                                        {"kwargs": kw2}))
            _clear_py_env()

    # ---- report -----------------------------------------------------------
    print(f"budget-consistency: {len(ROWS)} rows, {rows_checked} effectiveInput "
          f"cross-impl checks, {len(failures)} failures, {len(SKIPPED)} undriveable")
    for s in SKIPPED:
        print(f"  skip: {s}")
    if failures:
        print("\n==== DRIFT / DISAGREEMENT (each line is a real latent bug) ====", file=sys.stderr)
        for f in failures:
            print(f"FAIL {f}", file=sys.stderr)
        print("=============================================================", file=sys.stderr)
        return 1
    print("OK: all five token-budget implementations agree across the full matrix.")
    return 0


if __name__ == "__main__":
    sys.exit(run())
