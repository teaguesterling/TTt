# litinf — keeping the kernel live

A small, model-agnostic harness piece for driving lackpy's literate interpreter
(`LiterateSession`) across multiple rounds without the model rebuilding its own
state each time.

## The problem

`LiterateSession` is a multi-round fold over **one persistent kernel** — imports,
functions and bindings survive `@continue`. That is the whole point: bulk values
live in the kernel instead of the transcript, so context stops growing with turns.

But the literate contract tells the model that `@continue` *"returns all
variables to the caller, **who feeds them back**"*. If the caller doesn't, the
model has no evidence its earlier work survived, and defensively rebuilds.

Measured on `Qwen3-Coder-30B-A3B-Instruct` via the Tiiny, 3 trials each:

| continuation prompt | rounds | sent | rebuilt existing state |
|---|---|---|---|
| document only (naive) | 5 — **never terminated** | 24.0 KB | **12/12 rounds** |
| **document + kernel state** | **2** | **9.7 KB** | 2/3 rounds |

Feeding state back fixes **termination** outright and cuts bytes ~60%. It
reduces but does not eliminate rebuilding — a 30B model still sometimes redoes
step 1 when the task text says to. Larger models should comply better; the
harness is the same either way.

## The trap in the obvious fix

Feeding `session.scope` back verbatim **reintroduces the problem it solves**. A
scope entry for a 200-element list *is* that list serialised into the prompt, and
the kernel exists precisely so bulk values stay out of context.

So feed back **shape, not value**:

```
- fib: list[int], 200 items, starts [0, 1, 2]
- even_count = 67
- largest = 83621143489848422977
- cfg: dict, 2 keys, e.g. ['a', 'b']
```

331 chars for a namespace whose raw repr is 992 — and the ratio grows with the
data, which is the direction that matters.

## Use

```python
from kernel_state import continuation_prompt

res = await session.step(raw)
if res.continue_requested:
    body = continuation_prompt(res.variables, session.rendered)
    # send [system, {"role": "user", "content": body}]
```

State goes **before** the document deliberately — the model needs to know what it
has before it reads what it said.

## Notes for driving this on the Tiiny

- **Disable thinking.** With it on, reasoning models route the entire turn
  through `thinking` and return an empty document; the session then treats it as
  a retry. `chat_template_kwargs: {"enable_thinking": false}` on any model whose
  `thinking.toggleable` is true. This was the fatal failure mode in the first
  LitInf evaluation and it is fully avoidable.
- **Context stays flat**: 4.6 → 5.2 KB per round measured, against a standard
  conversation's linear +0.8 KB/turn. The literate contract costs ~4 KB fixed, so
  the approach pays off on long sessions and on tasks with bulky intermediate
  state — not on short ones.
- **Large payloads can crash the session** — this is not specific to images.
