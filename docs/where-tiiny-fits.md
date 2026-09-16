# Where Tiiny fits

Which work belongs on the device, given the rest of the toolchain sitting
alongside it: a cloud model, an always-on host, a workstation, roughly 450 GB
of local corpora, and a shelf of classical CPU tools.

Everything here is measured on this hardware. Where a number appears, it came
from a run.

This document separates **durable properties** (what the hardware and models
actually are) from **behaviour that needs a harness** — a supervisor, a
retry, a check — rather than a decision to avoid the device. Something that
needs thirty lines of supervisor code is not a reason to send work to the
cloud.

---

## The rule

**Give it bounded work that something else can check** — then build the harness
that makes it reliable. The device is free, private, always on, and has no rate
limit, which pays for a lot of harness.

The one hard line: **never let it be the only check on its own output.** Its
characteristic failure is fluent, confident and wrong, and every convenient
metric ranks that above the correct answer.

How far that goes, measured by EXPERIMENTER on `Qwen3-30B-A3B-Instruct`:
**offered two passages that were the same string, it chose one and reported high
confidence — and its choice tracked the answer token, not the content.** No fact
could make either the answer. It answered anyway. Swapping only which block was
labelled `A`:

```
labels A then B    answered A 11/12        CONFIDENT 12/12
labels B then A    answered A  8/12        CONFIDENT 12/12
                   answered "A"  19/24  p = 0.007   <- real
                   chose 1st block 15/24  p = 0.31   <- not established
```

So it is the **first-listed answer option**, not the letter and not the block
position: `A`, `FIRST` and `X` all go 12/12 as the opening choice, because all
three are simply the first thing offered.

**But the effect is bounded, and the boundary is sharp — which the paragraph
above overstated until this was measured.** Re-run on the vision model with the
same item asked both ways:

```
identical passages, no signal at all     first option chosen  12/12
real signal, same item asked both ways   same PASSAGE chosen  12/12
```

With content to go on it follows the content every time, and the answer letter
flips to track the passage. **The first option is an attractor toward a default,
and the default is only visible when the input supplies nothing.** So this is not
"it cannot compare" — it is "it answers even when there is nothing to compare",
which is a narrower and more useful claim.

It is also the more operationally dangerous half: the corruption lands precisely
on the cases where there was no right answer, which is exactly where a harness
most needs to be told nothing rather than something. Across four separate representations of "I don't
know" — a word, an index, a verdict option, and a confidence field — none was
ever used, in 100+ opportunities, *including where declining was the only
correct response*. Self-reported confidence on that model is not a weak signal,
it is not a signal: **47 of 48 confident** across every leg, including twelve
trials where the two options were the same string and twelve more where the
labels were reversed under it, with no difference between a leg it got right and
a leg where accuracy collapsed to chance.

Two caveats worth carrying with it. This is the 30B text model; on the 35B
vision model an `UNCERTAIN` verdict *was* used, once in 33, on a genuinely
ambiguous page — so it may be model- or modality-specific rather than universal.
The position-bias alternative was tested and rejected. What remains untested is
whether the letter preference is specific to `A`/`B` labels or would follow any
answer vocabulary. Neither caveat softens the operational rule: **do not ask the device how sure it is, and
do not treat a confident answer as a checked one.**

**And check every referent.** Anything the device emits that *names a
real-world object* — a file path, a symbol, a commit, an issue number, a plate
number — must be checked against the thing it names before a human reads it.
This is the general form of every failure in this document: the output's
*structure* is correct while a *referent* is fabricated.

Measured twice, independently. Asked to triage a repo issue, it called
`list_files("src/lackpy/kit/**/*.py")` **twice**, received `[]` both times, and
named `src/lackpy/kit/registry.py` anyway at `CONFIDENCE: high` — a directory
that does not exist. Re-run on the same issue with the same prompt, it was
correct. **Sampling variance, not a prompt defect**, and the note reads
identically confident either way. The same run dropped a `src/` prefix
elsewhere, which is the more dangerous shape because it looks right.

The filesystem, the test runner and the repo are authoritative and checking is
free. The model cannot enforce this and does not need to.

---

## What it can actually do

Measured here unless noted. Several of these were unexplored until today.

| capability | status | measured |
|---|---|---|
| Chat / instruct | 11 models | Coder-30B ~10 s median |
| **Tool calling, multi-turn** | **works** | 3-turn agent loop, correct, **4.9 s total** |
| Vision → text | 4 models | 3.9–5.2 s per bounded description |
| Embeddings | 1024-dim | **0.15 s** warm |
| **Reranking** | **works** | **0.29 s**, correctly ordered |
| ASR | available | offline recognition, forced aligner, interim results |
| Image generation | 5 models | untested |
| Music generation | 1 model | untested |
| TTS | **unavailable** | `/health` → `tts.available: false`; no TTS model in catalogue |

`GET /v1/capabilities` reports, for the currently loaded model: `supports_chat`,
`supports_vision`, `supports_images`, `supports_video`, `is_ocr`, input/output
modalities, `supported: ["Reasoning","Tool Use"]`, and the full `thinking`
object. **That is the readiness signal** — use it instead of inferring from the
catalogue.

---

## Where to apply it

### 1. Multi-turn agent loops — the biggest under-used capability

A three-turn loop (`list_files` → `read_file` → answer) completed **correctly in
4.9 s**, picking the right tool each turn, passing correct arguments, and
declining to call a tool when the question needed none.

This matters because the device's headline limitation was measured under a
harness that *forbade* it. A separate evaluation scored it **0/5** at deriving a
code repair — but that harness generated one program up front, so the model had
to write a string it could only know *after* reading a file. Supply the file
content and the same task goes **5/5**. A multi-turn tool loop removes the
constraint entirely.

**So "delegate execution, not diagnosis" was a fact about the harness, not the
model.** With native tool calling the device can fetch, inspect, decide and act.
Build agent loops on it.

**Worked example — overnight issue triage.** The clearest fit found so far, and
it exercises every property above. Fetch an issue, fetch the code it implicates,
classify, write a structured note. Measured on the real tool suite over a seeded
repo, told only *"a test is failing"*:

```
1  get_errors()                       -> ref_file, ref_line, message 'Asse...'
2  read_file(tests/test_priority.py)  -> the real test source
3  get_function(normalize_priority)   -> the body, via an AST selector
4  read_file(src/taskbin/priority.py) -> the module, for LEVELS
5  correct diagnosis                                      5 turns, 17.4 s
```

Turn 3→4 is the part that matters: the body referenced `LEVELS`, which the body
doesn't define, so it went back for the module. **A decision only makeable after
seeing a result** — the exact step a generated program cannot contain. It also
derived the symbol name from the test's import line, and diagnosed correctly from
a seven-character truncated message by reading the source instead of trusting it.

**Stop at evidence, not at a patch:** *here is the failing test, the implicated
function, the last commit that touched it, and a one-line hypothesis*. Retrieval
and structured summarisation are what it's good at; deciding what to change is
not.

**Design it against the contention profile:**

1. **Route through woollamad and do not name a model.** Ask for `tiiny/default`
   and take whatever is resident. A background job demanding a specific model
   *evicts* whatever a human is using — the job becomes the aggressor. Be
   residency-opportunistic, not model-prescriptive.
   *Note this inverts the benchmarking rule.* For a measurement you must name an
   explicit model, because `default` resolves against live residency and makes
   results non-reproducible. Same mechanism, opposite conclusion: name a model
   when you want **reproducibility**, take `default` when you want
   **politeness**. Don't carry either rule into the other context.
2. **Run in a window nobody else uses.** woollamad serialises requests, but does
   not queue across a *model swap* — if another consumer holds a different model
   you get an immediate 503, not a wait (woollama #39).
3. **Checkpoint per item and treat 503 as reload-and-retry**, never as "no
   findings" — an instance that stops responding returns 502 and then a run
   of 503s until it is explicitly reloaded.
4. **Alert on a short night.** If 40 issues go in and 12 come out, that is a
   failure, not a report.

At ~17 s per issue a 40-issue night is twelve minutes on otherwise-idle hardware.

### 2. Anything privacy-bound — the strongest case, and it needs no benchmark

Health records, family documents, household audio. This data **cannot go to the
cloud** regardless of how good the cloud is, so the comparison isn't
device-versus-Claude, it's device-versus-nothing. Embedding, search,
summarisation, classification and ASR over private material belong here by
default.

### 3. Corpus-scale embedding and retrieval

0.15 s per embedding, free, unlimited. Against ~450 GB of local ZIM and
survivorlibrary (2.1 M pages), cloud embedding is a real bill *and* a privacy
decision. Here it is neither.

Pair it with **reranking at 0.29 s**: retrieve broadly and cheaply with BM25 or
vectors, then rerank the top ~100 on the device. Two-stage retrieval where the
expensive stage is free.

### 4. Image content with no classical alternative

Plates, figures, diagrams, photographs. Measured on a book of engraved plates
whose entire searchable text was `No. 205.`:

| | precision@1, within-book |
|---|---|
| existing OCR text | **0/5** |
| device descriptions | **5/5** |

No cheaper non-fabricating tool exists, because there is nothing to read. And a
description is *derived* and labelled as such — it never masquerades as the
source.

**Harness:** segment to one subject per image. Isolation alone turned a blurred
two-vehicle blob into two distinguishable descriptions with correct plate
numbers, with no prompt change.

### 4b. Screening — asking the *detection* question, not the transcription one

The strongest measured fit so far, and it took no new capability — only a
cheaper question. On 33 pages where a classical extractor scored **0 words and
0 regions**, the device was asked "does this page contain any readable text?"
rather than "transcribe it":

| | |
|---|---|
| throughput | **17.4 pages/min** (2.92 s/page), controls included |
| recoveries | 4 YES + 1 UNCERTAIN out of 33 |
| errors, retries, unparseable | 0, 0, 0 |
| positives verified by eye | 5/5 real; 2 verbatim-exact, 1 a whole dense page |

One recovery was a full page of index entries so faint it reads as blank paper.
The device reported text it could not read rather than inventing a line —
the honest answer, and the one a transcription prompt would have punished it
into faking.

Why the classical tool loses is the part worth keeping. Photometric features
here are not weak, they are **inverted**:

```
                              sd     min    mean
verified-blank page          5.28    1.2    88.6
verified-dense-text page     3.47   29.3    87.3
```

The blank page has more variance and darker pixels than the page covered in
text, because a dark scan edge outweighs a page of faint ink. No threshold on
that feature space recovers the text page. The discriminator is whether marks
are *letterforms* — semantic, not photometric — which is exactly the axis a VLM
has and a region detector does not.

**The generalisable move:** the device is roughly even with `rapidocr` at
transcription and loses on dictionary rate, so competing there is a poor
trade. Detection is a different question — cheap, binary, and checkable — and
it is where the gap is decisive. Before delegating a hard task, ask whether an
easier question upstream produces the same value.

**Harness — three rules, in the order they cost something to learn:**

1. **Controls in every chunk, in *both* directions.** A run of 33 NOs is
   indistinguishable from a broken screener. A positive control fixes that —
   and catches nothing else: the `boundary` band came back **35/35 YES**, which
   an always-YES screener also produces while passing every positive control.
   Only a negative control on a page verified blank settled it.
2. **Controls drawn from a *different* band than the one under test.** A
   control from inside the band shares whatever makes the band hard, so it
   fails at the same moment as the thing it checks — and reports success right
   up until it does.
3. **Ground controls in something you looked at yourself,** never in the
   upstream tool's count. That tool is what's under test.

Errors, unparseable replies, and honest negatives must be three distinct
values; folding any pair together reproduces `errors-as-values` at the
experiment level — a check that cannot fail independently of the thing checked.

Overhead is small: controls were ~15% of requests on a 114-second run.

**Put the required output FIRST, and widen the schema before tightening it.**
Two prompt-shape findings, both larger than they look.

A completeness screen over 132 pages produced 11 replies that ignored the
three-line output format entirely. They were *good* replies — the model was
enumerating the page's text elements and reconciling them against the region
count, which is the correct procedure for the question — but the format had
nowhere to hold the work, so the verdict never arrived and the token cap cut
them mid-sentence. The instinct is a stricter grammar. That is the wrong move:
it discards the reasoning that made the answers right. Widening the schema
resolved 16/16.

The ordering matters more than the cap. Four pages still truncated at 900
tokens, reasoning past the summary. Moving the required block to the **front**
and letting elaboration follow resolved all four — and cut runtime from
24–82 s to **5.9–7.7 s**, because a model that has committed to a verdict stops
rambling. A capped output should degrade by losing the part nobody needs.

**The minority verdict is the fragile one — and it is the one you need.**
The hardest lesson of the screening work, found by running a framing control I
had written and left unexecuted.

A completeness screen returned 108 COMPLETE / 24 INCOMPLETE. Three arms, each
changing exactly ONE thing about the prompt, on the same pages at temperature 0:

| arm | what changed | COMPLETE held | INCOMPLETE held |
|---|---|---|---|
| ORDER | menu reordered | 4/4 | **1/7** |
| WORDING | question stem rephrased | 4/4 | **3/8** |
| EXAMPLE | the minority option gained a worked example | 4/4 | **1/8** |
| EXAMPLE-2 | that example swapped for a *representative* one | 4/4 | **2/7** |

**The majority class held 20 of 20 across all five conditions. The minority class
survived 7 of 30.**

The last row is there because it killed a good hypothesis. The proposed mechanism
was that an example does not illustrate a category but *replaces* it — the option
silently becomes "cases like THIS one" — so an unrepresentative example excludes
most true members. Testable, so it was tested: the atypical example ("a page of
body text") was swapped for one matching the actual population ("a plate with
labels scattered across the figure"). 1/8 became 2/7, **p = 0.569**. No effect.

Four different perturbations, same collapse. That is not four mechanisms — it is
**one default with a minority class that has no stability against anything**, and
the parsimonious account has no mechanism in it at all. Stop hunting for the
cause: the fragility is the finding, and it is fully specified without an
explanation.

This is the worst possible shape, because **the majority verdict is the one that
means "no action"**. All the operational value is in the minority class, and
that is exactly the class that does not reproduce.

Two consequences worth carrying:

- **The cheapest available diagnostic** (ZIM-Librarian's): *check whether a
  result agrees with its own first-listed option before trusting it.* Across
  four runs here it separated them perfectly — the two that went **against**
  their first option survived scrutiny; the two that went with it collapsed.
- **Treat concrete examples in prompts as a hazard, not a clarification.**
  Adding a worked example to the minority option made the model choose it *less*
  (1/8 held). Separately, a realistic example string placed in a prompt to show
  what did *not* count came back reported as a page's contents. Describe the
  property; do not illustrate it.

The general rule: **a verdict distribution is not a measurement until you have
perturbed the prompt and watched it survive.** One framing gives you a number,
not a result.

**Separate facts about the artefact from judgements about your purpose.** The
schema that worked carried both:

| field | kind | survives a change of purpose |
|---|---|---|
| `MISSING` — body text / figure labels / table cells / numerals | fact about the page | yes |
| `WORTH_IT` — is the missed text worth indexing | judgement about *your* corpus | **no** |

`WORTH_IT` was the most useful field and the most dangerous one. Slide-rule
scale numerals are noise for a text index and the entire content for someone
cataloguing instruments — the model is inferring an objective function from one
line of prompt and returning it with unearned confidence. Keep it as a prior
that saves you reading a hundred pages, store it *beside* the fact and never in
place of it, and mark it purpose-dependent. Re-target the corpus and `MISSING`
still means what it meant while `WORTH_IT` silently stops being true.

### 4c. Detection is safe to act on; transcription is not

The most portable rule the OCR work produced, and it decides *which output of
this device you can use without checking it.*

**The device's failures are always fluent.** It does not garble or stall — it
returns a confident, well-formed, plausible answer that happens to be wrong. So
the question is never "is it accurate", it is **"can I check this cheaply?"**

| output | checkable? | act on it? |
|---|---|---|
| **Detection** — is there text here, does this page have a caption | yes: binary, controllable, verifiable by eye in seconds | **yes** |
| **Transcription** — what does it say | no: verifying means reading the page yourself, which is the work you delegated | **only with a second source** |

Measured on two pages of cursive manuscript that `rapidocr` rendered as
gibberish:

```
daniels p84    device: "Two compound sounds sufficiently import"   <- exactly right
astronomy p67  device: "Wishes the letter very sincere."           <- page reads
                       "makes the factor y very small."               fluent, wrong
```

One for two, and **nothing in the second output signals that it is wrong**. This
generalises the earlier `sugur` → `sugar` finding, which looked like an
archive-fidelity quirk: it is the same thing. A normalisation and a confabulation
are both fluent, and fluency is exactly what defeats a cheap check.

**A worked use of the rule — disambiguating an OCR hallucination from unread
text.** Two signals over the corpus (lexicon hit rate, OCR confidence) flag
suspect pages, but they cannot separate the two cases that matter, because both
measure the output *string* while the distinction is a property of the *page*:

```
invented text on a page with none   -> discard, nothing to recover
real text the OCR could not read    -> RECOVER: often the best text in the band
```

Two of three flagged pages turned out to be full pages of legible handwriting.
A filter without a third stage deletes manuscripts silently. The fix routes only
the flagged cell to the device and asks the **detection** question — never the
transcription one:

```
lex<0.35 AND conf<0.80  ->  device: is there readable text on this page?
                              YES -> real text, unread. Route for recovery.
                              NO  -> invented. Discard.
```

One page in 162 here, so the device cost is nil, and the answer is the kind you
can spot-check by eye. That is the shape to look for: **let the device decide
something binary that something else can verify, and never let it be the sole
source of a string you will store.**

### 5. ASR over household audio

Offline recognition with a forced aligner and interim results. Voice notes,
recordings, dictation — high value and squarely privacy-bound. Untested; worth a
pilot.

### 6. Background work nobody is waiting for

The device is idle most of the day, and latency is its weakness — **batch work
doesn't care**. Tagging, classifying, summarising, enriching, indexing. A job
that runs overnight costs nothing.

### 7. Applying and verifying a described change

`fix-guided` — repair described, model applies it, `pytest` goes 1 failed → 0 —
passed on every model tested. Externally checkable, which is the property that
matters.

### 8. Energy — an axis worth weighing, and currently unmeasured

**The device's power draw is not measurable with what's here.** `scmi_sensors`
exposes 20 temperature sensors and **no power, current or voltage rail**;
`/sys/class/power_supply/` is empty; `sys/device_info` carries no TDP; and it is
not on a metering plug in Home Assistant. **A wall meter is the only route to a
real figure**, and a metering smart plug would put it in HA permanently.

What is measurable is the thermal signature. Six back-to-back plate descriptions
on the fully-loaded 35B:

| sensor | idle | +12 s | +26 s | after |
|---|---|---|---|---|
| NPU | 49 | 52 | **54** | 53 |
| SOC_TRC | 51 | 55 | **61** | 54 |
| CPU_B0 | 50 | 60 | 60 | 54 |

Peak ~+10 °C, decaying within seconds of the run ending. **Do not convert that to
watts** — thermal delta without thermal resistance is not power, and inventing
the number would be the same confident-fabrication failure this document warns
about everywhere else. Qualitatively it is a low signature: a part dissipating
serious wattage here would climb harder and hold.

**The comparison that matters is not per-page efficiency.** A CPU OCR engine wins
that on pages it can read — but its energy on a page it *cannot* read is entirely
wasted, and it burns it repeatedly: a rotation-selecting pipeline runs **four
detection passes** on a page it will never resolve. The device is
rotation-invariant and needs one.

So on the failing set the efficiency comparison inverts, and on the corpus the
device's share is negligible: **14,464 title pages** — one per book, display type,
unreadable by the detector — at a generous 100 J/page is ~0.4 kWh against the
5–6 kWh the bulk CPU pass costs regardless.

**Frame it as "many small problems", not "a bulk engine".** Every job in this
document is bounded and per-item; none of them is a corpus sweep. That is where a
low-power always-on appliance belongs.

### 9. Offline and degraded operation

When the internet is down, the device still works. For a household that is a
real availability tier.

---

## Delegating to the device from an AI agent

This document was written as a routing table for a human choosing tools. That
misses the axis that matters most here.

**The device does not exist to supersede a datacenter model. It exists so that a
datacenter model can delegate** — and so that anything small or private gets
screened locally *before* a cloud call is made at all.

Which makes the cloud instance part of the system being placed, not the observer
placing it. Worth stating plainly because it is easy to miss from the inside: in
one session establishing what the device could read, **this author read seven
page images through the cloud while the local vision model sat idle** on the same
network. Some of those were necessary. Most were not.

### Delegate by default

- **Screening before escalation.** *"Is there text on this page? Is this a plate,
  a table or prose?"* — bounded, per-item, and exactly the 3.9–5.2 s regime. Let
  the device triage a few hundred items and look only at what it flags ambiguous.
- **Anything private.** Health, family, household audio, personal documents. The
  cloud call is not merely more expensive, it is a disclosure. Screen locally and
  escalate only what genuinely needs it — ideally in redacted form.
- **First-pass reads where your role is verification, not discovery.** If you are
  going to check the answer anyway, you do not need to originate it.
- **Bulk small judgements.** Tagging, classifying, extracting a field. Nobody is
  waiting, the hardware is idle, and the marginal cost is electricity.

### Do it yourself

- **Independent ground truth.** If you are *scoring* the device, your read must
  not come from it. This is the one case where duplicating the work is the point.
- **The genuinely hard adjudication** the screen escalated to you — that is the
  division working, not a failure of it.
- **Novel architecture and ambiguous design judgement.**

### The shape

**Local screens, cloud adjudicates.** It is cheaper on every axis at once —
privacy, energy, latency, money — and it uses each side where it is measurably
strong. The device is good at bounded per-item work over material it can see; a
datacenter model is good at the small number of cases that survive the screen.

A corollary worth internalising: **"I'll just look at it myself" is the default
that quietly routes private data through a datacenter.** It is also usually the
slower path once there is more than a handful of items.

## Where a classical tool still wins

**Transcribing text an OCR engine can read.** Hand-verified, one dense page:

| | correct | dictionary rate | `sugur` typo |
|---|---|---|---|
| **rapidocr**, 4 s, local | **14/14** | 75.9% | **preserved** |
| device, tiled, ~180 s | 13/14 | 94.1% | silently "corrected" |

Classical OCR fails *visibly* (`setsof SMTparts`); the VLM fails *invisibly*
(`bags of SMT parts` where the page reads `sets`). One you catch, the other you
ship.

**But they are complementary, not ranked — and they fail on different *classes*
of page.** Measured on the three plates rapidocr could not read at any rotation:

| page | rapidocr | device |
|---|---|---|
| factory engraving, text only on a signboard inside the artwork | **zero regions, all four rotations** | found it, one word wrong |
| **title page, ornamental display type** | `OWNING / 8.00 / BBOI / WAGOINS` | **the whole page, correctly**, including the copyright small print |
| plate rotated 180° | `hloN` | `N° 114.` |

The title page is the decisive one, and the failure explains itself: **the only
line rapidocr nearly got right is the only line set in plain type.** Everything
it mangled is shadowed, swashed display lettering — `OWNING` is `DOWNING` minus
its drop-cap. No preprocessing fixes that; contrast, binarisation and upscale
address *legibility*, and the problem is *typeface*.

So the split is: **rapidocr for body text and plain type; the device for display
type, text embedded in artwork, and arbitrary rotation.** A title page is not a
rare case — it is page one of every scanned book.

**Routing rule, mechanical and cheap:** when the OCR engine returns zero regions,
*or* returns regions that fail a plausibility check for what you expect, route
that page to the device. Both failure classes above trigger it.

---

## Harness patterns for common failure modes

Failure handling learned by running real workloads against the device. None
of it is a reason to route work elsewhere — each pattern below is what makes
the device reliable enough to build on.

- **Treat a run of 502-then-503 as reload-and-retry, not as "no findings."**
  Recovery is clean once you do: an explicit `start` works immediately and
  the instance is serviceable again within 30 s.
- **Wait past the reap window before trusting `/models/running`.** A model
  that has just stopped serving can still be reported `running` for 2–5 s,
  with a stale `active_request_count`. Key recovery off the error you saw
  rather than the state the API reports.
- **Bound output length and watch for degenerate, looping generations.**
  Unique-line ratio cleanly separates healthy output (0.57–1.00) from a
  collapsed, looping one (0.02), with no overlap — a cheap check to run on
  anything long.
- **Retry on ambiguous input, not on clean input.** Clean input reproduces
  byte-identical across runs; ambiguous input (poor scans, dense layout,
  degraded print) draws a different answer each time. `n>1` is a live
  mitigation precisely because it's the failing cases that vary.
- **Don't build on `seed` or `logprobs`.** Neither behaves as documented on
  this device (see [`device-api.md`](device-api.md)) — treat anything that
  depends on them as unavailable rather than working around it.
- **Route contended traffic through one gate.** Two consumers each wanting a
  different model resident will fight over the same single-session device;
  routing everyone through `woollamad` serialises that instead.

---

## Placement by role

| work | where |
|---|---|
| Anything private — health, family, household audio | **the device**, always |
| Corpus embedding, reranking, semantic search | **the device** |
| Agent loops with tools | **the device** |
| Figure / plate / diagram description | **the device** |
| Overnight batch enrichment | **the device** |
| Bulk OCR of readable text | **rapidocr on CPU** |
| Pages where rapidocr finds no regions | **the device** |
| Faithful transcription of a source document | classical tool, or device plus verification |
| Novel architecture, ambiguous design judgement | **cloud** |
| Always-on watching, bridging, routing | **the always-on host** |

**Route everything through `woollamad`** — it serialises against a device that
wedges under concurrency, loads models on demand, and queues instead of failing.

---

## The one thing to keep in mind

Every failure documented here was **fluent**. None announced itself. So the
device earns its place wherever an external check exists — a test runner, a
retrieval target, a second engine, a schema, a checksum — and the harness that
supplies that check is usually small.

Build it, and the list above is long.
