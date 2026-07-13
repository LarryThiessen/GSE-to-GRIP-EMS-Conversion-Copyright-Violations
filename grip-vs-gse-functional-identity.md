# Exhibit — GRIP-EMS is functionally identical to GSE, and its stated point of difference is not implemented in its code

> **NOT LEGAL ADVICE.** Prepared by the rights holder for counsel. Findings are from GRIP-EMS's own shipped Lua (v2.3.5 tree: `Import/`, `Engine/`, `Core/`) and from decoding real `!GSE3!` / `!GRIP1!` / `!EMS1!` strings. Two-sided; confidence and review scope are stated.

## The honest boundary (read first)

This exhibit claims **behavioral / architectural / format identity** — GRIP does the same things GSE does, the same way, and reads/writes the same shape of data. It does **NOT** claim GRIP's **source code is copied** from GSE. That is not a deferral to any prior assumption: a full five-subsystem source-to-source diff of both codebases was performed for this package (see `grip-vs-gse-forensic-comparison.md`) and found no copied source in any subsystem — and found affirmative disproof of a "copied-then-renamed" theory (GSE's ChaCha20 codec and its CBOR delta engine are absent from GRIP; GRIP's ReversePriority/Random modes diverge). "Functionally the same" ≠ "copied code," and the evidence supports the former, not the latter. The relevance is to rebut GRIP's public positioning as a *different and better* engine, and to show it is a GSE-compatible reimplementation purpose-built to ingest GSE creators' sequences. The full comparison (including the one design match — GSE's Priority expansion, output-identical in GRIP — the anti-scrape lock workaround, and the owner-ID removal) is in `grip-vs-gse-forensic-comparison.md`.

---

## Part 1 — Where GRIP is the same as GSE

### 1. Export/import container — **identical**
Both use the exact same pipeline (GRIP's `Import/Serialization.lua`):
```
CBOR  ->  CompressString (raw DEFLATE)  ->  Base64  ->  "!PREFIX!"
```
GRIP's `Serialization.DetectFormat` recognizes `EMS1`, `GSE3`, `GSE3_ENCRYPTED`, `GRIP1`, `FRG1`, `GEMSCP1` and decodes them through **one** shared routine (strip prefix → Base64 → decompress → CBOR). `!GSE3!` and `!GRIP1!` differ **only in the CBOR table inside** — the encoding, compression, and Base64 are the same bytes-for-bytes process. *Verified:* the same Node decoder (`pako.inflateRaw` + `cbor-x`) decodes both an authentic `!GSE3!` and a LazyGrip-produced `!GRIP1!` (see `evidence/lazygrip-webtool/`).

### 2. Data model — **the same concepts, renamed keys**
| GSE (`!GSE3!`) | GRIP (`!GRIP1!`) | Same thing? |
|---|---|---|
| `Sequences` | `sequences` | yes |
| `Versions` | `versions` | yes |
| `Actions` (macro blocks) | `actions` | yes |
| `StepFunction` (Sequential/Priority/Random) | `stepFunction` | yes — same set |
| `Type: "Loop"` + `Repeat` | `type: "loop"` + `repeat` + `children` | yes |
| `InbuiltVariables` (Combat/Head/...) reset triggers | `resetOnCombat` / `resetOnTarget` / `resetOnGear` / `resetOnSpec` | yes |
| `KeyPress` / `KeyRelease` | `keyPress` / `keyRelease` | yes |
| `MetaData.Author` | `author` | yes |
| macro text (`/cast`, `/castsequence`, `[cond]`) | macro text (`/cast {spell:ID}`, `[cond]`) | yes |

GRIP's `Import/LegacyImport.lua` reads GSE's `Sequences` / `MacroVersions` / `MetaData` / `StepFunction` / `InbuiltVariables` directly and maps them into the GRIP model above — i.e., GRIP's own code treats the two models as trivially interconvertible.

### 3. Secure engine architecture — **the same technique**
GRIP's `Engine/Engine.lua` builds each keybind as a
`CreateFrame("Button", …, "SecureActionButtonTemplate,SecureHandlerBaseTemplate")`
with `type="macro"`, a `step` attribute, and a `WrapScript(btn,"OnClick",clickBody)` that swaps the macro text and advances the step in the restricted (secure) environment. This is the standard one-button macro-sequencer construction GSE uses.

### 4. Step advancement — **advance-every-press, same as GSE**
The default Sequential step function's secure body (`Engine/StepFunctions.lua`, Sequential `BuildClickBody`) ends with:
```lua
step = step % numS + 1
self:SetAttribute('step', step)
```
It loads the current step's macro and then **unconditionally advances to the next step on every keypress** — identical to GSE's core behavior. Priority and Random are step-*selection* variants (round-robin weighting / random pick) over the same advance-on-press model.

### 5. Conditionals — **the same native WoW macro syntax**
`Engine/MacroConditionalBaker.lua` maps GRIP's helper functions to native WoW macro conditionals: `InCombat→[combat]`, `HasMod→[mod]`, `InStance→[stance]`, `InForm→[form]`, `InSpec→[spec]`, `IsStealthed→[stealth]`, `IsDead→[dead]`, `IsHelp→[help]`, `IsHarm→[harm]`, `UnitExists→[exists]`, `InParty→[party]`. These are the exact `[condition]` tokens GSE macros already use.

**Net:** same container, same data model, same secure-button technique, same advancement behavior, same conditional language, same step functions, same reset/keypress concepts. GRIP is a GSE-compatible reimplementation.

---

## Part 2 — The stated point of difference is not in the code

GRIP/LazyGrip's public positioning is that its **engine is fundamentally different from GSE**: it "holds" on a failed cast instead of "skipping." Quoted from `lazygrip.net` (captured 2026-07-12):

- *"GRIP-EMS is a World of Warcraft rotation addon that **holds its place when a cast fails instead of skipping ahead**."*
- *"Holds on failed casts — **the sequence stays where it is until the cast lands**, not where the engine decided to move."*
- *"Cooldowns on schedule — high-priority abilities fire when the sequence reaches them, not whenever the engine cycles back around."*
- *"Consistent across keys — the same sequence produces the same uptime numbers pull to pull because **the execution model doesn't drift**."*
- *"That's not a promise. It's what the logs show … around **an engine that doesn't skip**."*

### What the code actually does
- The Sequential secure body **advances every press unconditionally** (`step = step % numS + 1`, above). There is **no** "wait until the cast lands" logic — no `IsUsableSpell`, no cooldown check, no cast-success gate in the advancement path.
- The **only** `UNIT_SPELLCAST_SUCCEEDED` handler in the entire engine (`Engine/Engine.lua`) fires for **spell 384255 "Changing Talents"** — a loadout/talent-swap signal — **not** the rotation. Nothing in the rotation engine reads whether the previous ability succeeded.
- This is also **architecturally required**: WoW does not expose synchronous cast success to secure/restricted code, so a secure `OnClick` **cannot** decide "the cast failed, don't advance." No addon can implement the marketed mechanism in the secure button, and GRIP's code does not attempt it.

### The consequence
GRIP advances its step on every press exactly as GSE does. The claimed differentiator — "holds on failed cast," from which the "cooldowns on schedule," "no drift," and "consistent logs" claims all follow — **is not implemented by GRIP's engine.** Where genuine hold-on-cast behavior appears in a sequence, it comes from **Blizzard's native `/castsequence`** written *inside the macro by the sequence author* (e.g., the rights holder's SLG-DK-BLD uses `/castsequence … reset=target …`), not from any GRIP engine feature — and that is a WoW facility available identically to GSE users.

### Confidence / scope
High confidence on the default path: the Sequential `BuildClickBody` was read in full; the engine's complete event table was reviewed (only the talent-swap `SPELLCAST_SUCCEEDED`); `MacroConditionalBaker.lua` was read. Not exhaustively read: every line of `Engine/ActionCompiler.lua` and every non-default step function body. No advance-gating-on-cast-success was found in what was reviewed, and the secure-code architecture forecloses it.

---

## Part 3 — Why this matters (for counsel)

- **Rebuts the "different engine" positioning.** GRIP is marketed as a distinct, superior engine; on the evidence it is a GSE-compatible reimplementation whose signature differentiator is not present in its code. This bears on any "transformative / independent tool" defense and on consumer-facing representations.
- **Supports the ingestion narrative.** The format/model identity is *why* GRIP can bulk-import GSE creators' sequences and re-emit them (the core complaint), and *why* the LazyGrip web tools can decode and convert them (`grip-lazygrip-webtool-exhibit.md`).
- **Not a code-copying claim.** Reiterated: this is behavioral/architectural/format identity, consistent with the finding that the *source code* is independently written. Do not let it drift into a copying allegation.
- Marketing-claim accuracy (Part 2) is a **factual** finding about the product, not a legal conclusion; whether it supports any false-advertising / unfair-competition angle is for counsel.
