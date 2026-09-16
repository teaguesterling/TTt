"""Keep the LitInf kernel live across rounds.

The literate contract tells the model that `@continue` "returns all variables to
the caller, who feeds them back". If the caller doesn't, the model has no way to
know its earlier work survived — so it defensively rebuilds state every round.
Measured on Qwen3-Coder-30B: 4 of 4 continuation rounds recomputed a list it
already had.

The naive fix — feed `session.scope` back verbatim — reintroduces the problem it
solves, because a scope entry for a 200-element list *is* that list serialised
into the prompt. The kernel exists precisely so bulk values stay out of context.

So: feed back **shape, not value**. Scalars show their value; containers show
type, length and a short sample. The model learns what it has without paying to
carry it.

Model-agnostic: nothing here is Tiiny-specific, and it applies to any backend
driving a LiterateSession.
"""
from __future__ import annotations

SCALARS = (int, float, bool, str, type(None))


def describe(name: str, value: object, sample: int = 3, str_cap: int = 80) -> str:
    """One line describing a binding: full value if small, shape if not."""
    if isinstance(value, SCALARS):
        r = repr(value)
        return f"{name} = {r}" if len(r) <= str_cap else f"{name}: {type(value).__name__}, len {len(r)}"
    if isinstance(value, (list, tuple, set)):
        kind = type(value).__name__
        head = list(value)[:sample]
        inner = {type(x).__name__ for x in list(value)[:20]}
        it = inner.pop() if len(inner) == 1 else "mixed"
        return f"{name}: {kind}[{it}], {len(value)} items, starts {head!r}"
    if isinstance(value, dict):
        keys = list(value)[:sample]
        return f"{name}: dict, {len(value)} keys, e.g. {keys!r}"
    mod = getattr(type(value), "__module__", "")
    shape = getattr(value, "shape", None)
    if shape is not None:
        return f"{name}: {mod}.{type(value).__name__}, shape {shape}"
    return f"{name}: {type(value).__name__}"


def state_block(namespace: dict, skip: set[str] | None = None) -> str:
    """The block to put in front of the document on a continuation round."""
    skip = skip or set()
    rows = [describe(k, v) for k, v in namespace.items()
            if not k.startswith("_") and k not in skip and not callable(v)]
    if not rows:
        return ""
    return ("## Kernel state — ALREADY COMPUTED AND STILL LIVE\n\n"
            "These names are bound in the running kernel. Use them directly.\n"
            "Do NOT rebuild them; recomputing is wasted work and may diverge.\n\n"
            + "\n".join(f"- {r}" for r in rows))


def continuation_prompt(namespace: dict, rendered: str, skip: set[str] | None = None) -> str:
    """State first, document second — the model needs to know what it has
    before it reads what it said."""
    block = state_block(namespace, skip)
    parts = [block] if block else []
    parts.append("## Document so far\n\n" + rendered)
    parts.append("Continue from here. Emit @done when the task is complete.")
    return "\n\n".join(parts)
