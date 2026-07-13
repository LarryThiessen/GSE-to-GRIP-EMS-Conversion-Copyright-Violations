# Exhibit — GRIP-EMS is a functional & design clone of GSE that circumvents GSE's content locks and strips the owner identity

> **NOT LEGAL ADVICE.** Prepared by the rights holder for qualified counsel. Findings are from a source-to-source comparison of the two shipped codebases (GRIP-EMS v2.3.x tree and the GSE-Advanced-Macro-Compiler source), performed subsystem-by-subsystem with line citations. Two-sided by design; the honesty boundary is stated up front and honored throughout.

## The claim, precisely stated

GRIP-EMS **is not alleged to contain GSE's source code.** The comparison found the opposite in several places (see the "what disproves a source copy" note). The claim is narrower and fully supported by the code:

**GRIP-EMS is a functional and design clone of GSE — it performs the same base functions, reproduces GSE's signature behavior, is built specifically to read GSE's data, engineers a workaround for the lock GSE placed on its content, and removes the identifier that ties each sequence to its GSE creator — implemented in independently written source.**

"We don't care that it is different code" is exactly right as a legal posture: the interest here is in the **same base functions, the same signature design, and the conduct around GSE's content** — not in whether the `.lua` text matches.

## Method

Five subsystems were compared independently, each reading both codebases in full and citing FILE:LINE on both sides: (1) serialization/codec, (2) checksum/signature/identity, (3) data model + sync, (4) the GSE-import path, (5) the secure engine + step functions. Each result was labeled **PLATFORM-MANDATED** (Blizzard/Ace forces this — proves nothing), **INDEPENDENT-REIMPL / INTEROP** (same behavior, independent code), or **COPIED** (matching source). No subsystem returned COPIED.

---

# Part 0 — Precedence: the copying is one-way, and "independent invention" is off the table

GSE (Gnome Sequencer Enhanced) dates to ~2015–2016; its Priority step-function and macro-sequence design have been GSE's signature for **~12–13 years**. GRIP-EMS is a 2026 addon (first release in the version scan is v1.0.4; the `PlatformID` GRIP omits was introduced by GSE on 2026-04-25). Consequences:

- **Every similarity flows GRIP ← GSE.** GRIP's authors had over a decade of GSE to study; GSE could not have derived anything from GRIP.
- **No convergent-evolution defense.** GRIP reads GSE's *specific* choices — the `!GSE3!` prefix, the `GSESequences[classID][name]` layout, the `MetaData`/`Versions`/`Actions`/`InbuiltVariables`/`StepFunction` vocabulary, and the Priority output ordering. These are GSE's original design decisions, not anything the platform dictated. Reproducing them is derivation from GSE, established as prior art by more than a decade.

---

# Part 1 — "The same car": it looks and runs like GSE because it replicates GSE's functions and signature design

The honest way to read the similarities is in two layers. Being candid about the first layer is what makes the second layer credible.

## Layer A — Sameness that Blizzard forces (this alone proves nothing, and we concede it)

WoW's protected-action rules leave **exactly one** way to build a one-button macro sequencer, and GSE has operated within those constraints for over a decade. Any compliant sequencer will therefore share:

- A secure button `CreateFrame("Button", …, "SecureActionButtonTemplate,SecureHandlerBaseTemplate")` with a `WrapScript(btn,"OnClick",…)` body that swaps `macrotext` and advances a `step` attribute in the restricted environment. (GRIP `Engine/Engine.lua` + `Engine/StepFunctions.lua`; GSE `GSE/API/Storage.lua:2359-2575`.)
- The 1-based round-robin advance `step = step % N + 1` — the only correct way to cycle a 1-based array; it appears even in GSE's own test `spec/prioritycheck.lua:37-41`.
- Clearing conflicting `macro`/`macrotext`/`unit` attributes each press (a hard SecureActionButton requirement).
- `SetBindingClick`/`SetOverrideBindingClick` straight to a named secure button (Blizzard's 11.0.2 macro-chaining restriction forecloses `SetBindingMacro`).
- Blizzard's native `C_EncodingUtil` for CBOR + compression + Base64 (the only in-client serializer).

**We concede Layer A freely.** Convergence on platform-forced technique is not evidence of anything, and saying so protects the rest of this exhibit. Blizzard "made it so there is only one way to do this," GSE has worked within that for years, and any honest sequencer will look similar here.

## Layer B — Sameness Blizzard does NOT force: GSE's original design choices, reproduced in GRIP

Nothing below is required by WoW. These are GSE's creative/engineering choices, and GRIP reproduces them.

### B1. The Priority expansion — GSE's signature algorithm, output-identical in GRIP
GSE's "Priority" step function expands a rotation into a **triangular `N·(N+1)/2` weighted round-robin**: step *i* is weighted `N−i+1`, arranged as concatenated increasing prefixes. For N=3 the emitted order is **`[1, 1, 2, 1, 2, 3]`** (step 1 ×3, step 2 ×2, step 3 ×1).

- GSE: `GSE/API/Storage.lua:2155-2171` — `looplimit = Σ(1..N)` then a stateful `limit/step` walk.
- GRIP: `Engine/StepFunctions.lua:248-262` (`ExpandPriority`) — a clean nested `for i=1..N / for j=1..i` double loop.

**Different code; byte-identical output ordering.** This is the single most probative point in the entire comparison: Priority is not platform-mandated, it is GSE's distinctive design and has been for over a decade, and GRIP reproduces its exact behavior. (Its neighbor modes ReversePriority and Random *diverge* — which is why this is design/behavior replication, not a line copy: GRIP re-derived the observable behavior.)

### B2. GSE's wire format and field vocabulary, hard-coded into GRIP
GRIP reads GSE's exact stored schema — not a public API, GSE's *internal* format:
- Globals `GSESequences[0..13][name]`, `GSE.Library`, `GSEVariables`, `GSEMacros`, `GSE_C` (`Import/LegacyMigrate.lua:57-207,262-395`), matching GSE's own layout (`GSE/API/Storage.lua:769-782`, `Statics.lua:4`).
- The `{name, seqObj}` on-disk envelope (`LegacyMigrate.lua:195-207` vs GSE `Storage.lua:141-143,562`).
- The field set `Versions`/`MacroVersions`, `MetaData.{Default,Author,SpecID,GSEVersion,Checksum,Dependencies,Disabled,Icon}`, `StepFunction`, `InbuiltVariables.{Combat,Head}`, `KeyPress`/`KeyRelease`, and the 11-key context vocabulary `Normal,Raid,Arena,PVP,Mythic,MythicPlus,Heroic,Dungeon,Timewalking,Party,Scenario` (`LegacyImport.lua:24-36,494-916` vs GSE `Storage.lua:1059-1071` — identical key set).

### B3. The same base data model and feature set
Sequence → versions → a step function over an action tree of Action/Loop/If nodes + reset triggers + keypress macros. GRIP renames GSE's keys (PascalCase→camelCase) and restructures the containers, but the **concepts and features are GSE's**: the same step-function names (`Sequential/Priority/ReversePriority/Random`), the same reset-to-step-1 behavior, the same loop/if/action semantics.

**Layer B conclusion:** stripped of the platform-forced boilerplate, GRIP still replicates GSE's *non-mandated* signature design — most starkly the Priority output. It looks and runs like GSE because it reproduces GSE's original functions and behavior, which GRIP's authors demonstrably studied (they read GSE's internal format to do it).

---

# Part 2 — "Picking the lock": GRIP engineered a workaround for the protection GSE placed on its content

This is conduct, and it shows knowledge and intent, not incidental interop.

- **GSE deliberately locked its content against third-party reading.** GSE wraps its runtime library in a protective proxy for the express purpose of blocking scraping — `GSE/API/Storage.lua:9-16` documents it as *"a minimal locked proxy … to deny in-memory scraping by third-party addons."* GSE took an affirmative protective measure.
- **GRIP wrote code specifically to get around that lock.** When GSE's runtime table is unavailable because it is locked, GRIP falls back to reading GSE's raw SavedVariables directly — `Import/LegacyMigrate.lua:92-99` documents the workaround: *"newer source builds keep the runtime table private,"* so GRIP reaches into `GSESequences` on disk instead (`LegacyMigrate.lua:195-207`).
- **This is intentional, not accidental.** The fallback exists *because* GSE hid the data; GRIP's own comments acknowledge GSE's privacy measure and route around it. A tool that merely wanted a user's own data casually would not document and engineer past a named anti-scraping lock. The workaround is evidence of knowledge of GSE's protection and a deliberate decision to defeat it.

**What the lock was protecting: the creators' licensed content.** GSE's anti-scraping proxy is the technical measure guarding the sequence library — which includes the rights holder's **SLG-Sequences, published "All Rights Reserved"** (`SLG-Sequences-LICENSE.txt`: no redistribution, no derivatives, no removal of attribution). GSE put a lock on third-party access to that content; the rights holder additionally reserved all rights over his own works within it. GRIP's engineered workaround reaches around **that** lock to read **that** content — the very sequences whose license forbids exactly this reproduction/derivation. So the circumvention is not abstract: it is the mechanism by which GRIP obtains All-Rights-Reserved sequences it is not licensed to copy, and it does so with documented awareness that GSE had affirmatively blocked such access. (GSE's own protected/subscriber content, encrypted with the ChaCha20 codec GRIP lacks, GRIP cannot reach and refuses — so the workaround's practical reach is precisely the *un-encrypted, licensed-but-not-DRM'd* creator content, including the rights holder's ARR sequences.)

*(For counsel: whether reading another addon's SavedVariables around an in-memory proxy implicates any anti-circumvention theory is a legal question — the SavedVariables are plaintext on the user's disk, so this is not classic DRM circumvention. The point here is intent and non-consent: GSE said "no scraping," and GRIP built a bypass.)*

---

# Part 3 — "Cutting the name-tag off": GRIP removes the identifier that ties each sequence to its GSE owner

This is the heart of the malicious-intent argument, and the code is unambiguous.

## What GSE puts on every sequence (the owner's name-tag)
Each GSE sequence carries, in `MetaData`:
- **`PlatformID`** — the GSE.Tools server-record identity, bound to the author's account. GSE treats it as an ownership value: it is preserved on rename and **deliberately cleared on duplication** so a copy "never resolve[s] to the same server record" (`GSE/API/Storage.lua:704-705,743-745`).
- **`HelpURL`** = `https://gse.tools/sequences/<PlatformID>` — a human-readable link straight to the owner's canonical listing.
- **`Checksum`** — a GSE.Tools **Ed25519 server signature** (verified against a baked-in platform public key, `GSE/API/Checksum.lua:53-113,150-153`) attesting the sequence is the authentic published version.

Together these are the sequence's provenance: *who owns it, where it lives, and proof it's unaltered.*

## What GRIP does with the name-tag
- **`PlatformID` — removed entirely. Zero occurrences in GRIP's entire ~9,000-file tree.** GRIP never reads, stores, or carries it. On import it stamps its *own* provenance instead (`Import/LegacyImport.lua:857-872`, `provenanceSource = "gse-legacy"`).
- **`HelpURL` (the gse.tools link) — not carried** into GRIP's model or its exported/shared output.
- **`Checksum` — dropped from the shared/exported artifact.** (The addon does read and store it inert internally as `importMeta.sourceChecksum` at `LegacyImport.lua:686-687`, but it is never verified or surfaced, and it is absent from the GRIP export/convert output — confirmed by decoding a live LazyGrip GSE→GRIP conversion, see `grip-lazygrip-webtool-exhibit.md`.)
- **`Author` (the human name) — retained.** GRIP keeps the display name. (Stated plainly for candor; the removed items are the *machine-verifiable ownership linkage*, not the display name.)

## Why removal evidences intent
`PlatformID` has **no function inside GRIP** — it is a GSE.Tools server key that means nothing to GRIP's engine. There is exactly one reason to go out of your way to *not carry* the one field that binds a sequence to its owner's server record and canonical listing: to sever the work from its owner. GSE itself treats `PlatformID` as the ownership handle (it wipes it on copy precisely so copies can't impersonate the original record). GRIP strips it on ingest. A tool merely importing content for a user's convenience has no reason to remove an inert owner-identifier — its removal is consistent with detaching creators' work from the creators, which is the conduct this GSE ecosystem's licenses exist to prevent.

## The removal happens at *every* stage — addon **and** public website

The identifier stripping is not confined to the addon's private import. The **same operator** runs a public, on-demand web service that performs the same removal — so the conduct is repeated in a second, independently verifiable venue.

**Operator nexus.** Per the rights holder, **sirsataana / "Sataana"** owns the **LazyGrip.net** site and authors **GRIP-EMS**, operating with **"Beard3d_Gamer"** and **"Slowdog"** (the Workshop tools page is titled "Tools by Beard3d_Gamer … integrated on LazyGrip by Slowdog"). *To be confirmed by counsel via CurseForge project ownership + WHOIS + the House of Lazy Macros Discord record.* The significance: the party stripping owner-IDs in the addon is the same party stripping them on the website.

**Vector 1 — the addon import** (documented above): `PlatformID` dropped, `HelpURL`/`Checksum` absent from the shared/exported artifact.

**Vector 2 — the public LazyGrip "Decode Export" web tool** (`/workshop/decode`), documented in full in `grip-lazygrip-webtool-exhibit.md`. Two acts in one tool, both reproduced live and captured:

1. **It hands out the full copyrighted work in plaintext.** Submitting the rights holder's own `!GSE3!` export renders every macro line verbatim in the browser (the SLG-DK-BLD `/castsequence …`, `/cast Reaper's Mark`, `/cast Marrowrend`, the Loop/Priority block). No converted output is even required to obtain the work — the decoder itself reproduces it. This is a public service performing reproduction of All-Rights-Reserved content on demand.
2. **It strips the owner-IDs in the same breath.** Decoding that same string through their server API (`POST /api/workshop/decode`, HTTP 200) returns the sequence with the human `author` name kept but **no `PlatformID`, no `Checksum`, no `HelpURL`, and no `gse.tools` reference anywhere** — the ownership linkage removed at the decode stage, before any conversion.

**Vector 3 — the "Convert to GRIP" web tool** re-emits a `!GRIP1!` string with `PlatformID`/`HelpURL`/`Checksum` gone (before/after captured on a third-party sequence; the rights holder's own collection was *refused* by name — "Sequence 'SLG-DK-Oh-!@#$' has no convertible macro blocks").

**One argument, three venues.** Whether the sequence is imported into the addon, decoded on the website, or converted on the website, the owner-identifying `PlatformID` (and the `gse.tools` source link, and the integrity `Checksum`) is removed at each stage while the work itself is preserved and, on the website, reproduced in plaintext for anyone logged in. A single inert server key does not get removed three different ways by accident; it is removed because it is the thing that ties the work to its owner. Both web vectors are **server-side and login-only** (any account, no paid tier) — the capability is offered to the public.

---

# What disproves a *source-code* copy (stated for credibility, and because it matters)

Being honest here is what lets the rest stand up. If GRIP had copied then merely renamed GSE's source "to hide it," GSE's distinctive artifacts would have come along. They did not:

- GSE encrypts protected/subscriber content with a **ChaCha20 cipher + embedded key** (`GSE/API/Codec.lua`). GRIP has **no decryptor** and refuses that content outright. A copy would carry the cipher.
- GSE's most distinctive engineered artifact — the **CBOR delta/diff sync engine** (`GSE/API/SequenceDelta.lua`) — is **entirely absent** from GRIP.
- GRIP's **ReversePriority and Random modes diverge** from GSE's; a line copy would have inherited them unchanged.
- Every field is systematically renamed and every structure reorganized; GSE's signature interleaved-numbered-key block layout is discarded for a clean `children[]` array.

The correct characterization is therefore **reverse-engineered functional/design clone**, not source theft. This is precisely what one would expect from either careful black-box re-implementation *or* automated same-function/different-code transpilation — the code cannot distinguish which, so this exhibit asserts neither method as fact (see next).

---

# On method (the rights holder's contention)

The rights holder contends that GRIP's authors took GSE's code and regenerated same-function/different-source code (e.g., via an AI transpilation step) to obtain GSE's behavior while avoiding literal copying. **The code artifacts are consistent with this, but do not prove it:** independent manual reverse-engineering produces the same fingerprint (same behavior, restructured code, GSE's distinctive artifacts absent). No source-level watermark identifies the tool or method used. Counsel should treat the method as an allegation to be developed through discovery (e.g., the authors' own statements, commit history, or development tooling), not as a fact established by the shipped binaries. The *behavioral and format derivation from GSE*, the *lock workaround*, and the *identifier removal* are established by the code regardless of method.

---

# Overall determination & what to plead

| Subsystem | Verdict | Confidence |
|---|---|---|
| Serialization / codec | Independent reimpl (black-box; GSE's ChaCha20 codec absent) | High |
| Checksum / signature / identity | Independent reimpl (Ed25519-server-signed vs keyless hash) | High |
| Data model / CBOR-delta sync | Independent reimpl (GSE's delta engine absent) | High |
| GSE-import path | Independent interop parser reading GSE's internal format | High |
| Secure engine / step functions | Independent reimpl; **Priority output byte-identical** (design match) | High |

**Do plead / develop:**
1. **Copyright infringement + SLG All-Rights-Reserved license breach** (the package's spearhead) — reproduction/distribution of the sequences; unaffected by the code question.
2. **Design/behavior appropriation** — GRIP replicates GSE's non-mandated signature design (the Priority triangular expansion, output-identical), established as GSE's for ~12–13 years. (Legal viability for counsel.)
3. **Removal of owner-identifying information (CMI)** — `PlatformID` + `HelpURL` + `Checksum` stripped; supports the §1202 count in `grip-1202-cmi-analysis.md`, strengthened here because the removed set includes a human-readable `gse.tools` **link** and an integrity **signature**, not merely an opaque key.
4. **Intent/non-consent conduct** — GRIP's engineered workaround around GSE's documented anti-scraping lock.

**Do NOT plead:** source-code copying, or the AI-transpilation method as established fact. Both are unsupported by the shipped code and both hand GRIP an easy, credibility-damaging rebuttal.
