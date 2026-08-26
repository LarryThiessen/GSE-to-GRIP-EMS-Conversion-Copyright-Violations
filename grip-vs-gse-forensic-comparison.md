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

**Operator nexus.** **`sirsataana` / "Sataana" — Jesper Driessen** authors **GRIP-EMS** and runs the **LazyGrip.net** site, operating with **"Beard3d_Gamer"** and **"Slowdog"**, who built and integrated the Workshop tools (the tools page is titled "Tools by Beard3d_Gamer … integrated on LazyGrip by Slowdog", and both describe their own roles in the Discord record). **Resolved 2026-07-29 — see `OPERATOR-IDENTITY-RESOLVED.md`.** The domain's registrant of record remains privacy-redacted and a subpoena is the route to it; that is a records question, not a question of who operates the site. The significance: the party stripping owner-IDs in the addon is the same party stripping them on the website.

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

> **Note on verifying these two bullets (added 2026-08-01).** `GSE/API/Codec.lua` and
> `GSE/API/SequenceDelta.lua` live in the **GSE source repository**, not in the packaged
> CurseForge release — neither file is present in `evidence/GSE-3.3.22.zip`. Checking these
> claims against a downloaded release will therefore appear to disprove them; check the source
> tree. Both were re-verified in source on 2026-08-01: `Codec.lua` implements ChaCha20 (sigma
> constants `1634760805, 857760878, 2036477234, 1797285236`; quarter-round rotations 16/12/8/7;
> ten double-rounds), and `SequenceDelta.lua` is 352 lines of CBOR delta/diff code.
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

---

# Appendix A — Verbatim extracts, so every claim above can be checked without unpacking anything

Every citation in this exhibit is `FILE:LINE`. This appendix reproduces the cited code on **both** sides so a reader — counsel, a platform reviewer, or the opposing party — can verify the findings from this document alone. Quoted for criticism and analysis; no derivative or modified build is distributed.

**Exactly what was read:**

| Side | Source | Version / anchor |
|---|---|---|
| GRIP-EMS | `GRIP-EMS-v2.3.5.zip` — the author's own CurseForge release package (project 1489414, file ID `8364957`, uploaded 2026-07-03) | SHA-256 `b50ca92e643024fdef84477b325ba0cfaa1056967a077183634d1a8218bd8d2a` · 272 entries, 182 `.lua` files |
| GSE | `github.com/TimothyLuke/GSE-Advanced-Macro-Compiler` working tree | commit `23c9cd97` (2026-07-17) |

Line numbers below were re-derived from those exact artifacts on 2026-07-29, not carried over from earlier drafts.

## A1 — The Priority expansion: different code, identical output

The single most probative point in this exhibit. Priority is not platform-mandated; it is GSE's design choice, and has been for over a decade.

**GSE** — `GSE/API/Storage.lua:2155-2171`. A stateful `limit`/`step` walk over a triangular `looplimit`:

```lua
2155|                 local looplimit = 0
2156|                 for x = 1, #actionList do
2157|                     looplimit = looplimit + x
2158|                 end
2159|                 if action.StepFunction == Statics.Priority then
2160|                     for _ = 1, looplimit do
2161|                         table.insert(returnActions, actionList[step])
2162|                         if step == limit then
2163|                             limit = limit % #actionList + 1
2164|                             step = 1
2168|                         else
2169|                             step = step + 1
2170|                         end
2171|                     end
```

**GRIP** — `Engine/StepFunctions.lua:248-262`. A clean nested double loop:

```lua
248| function SF:ExpandPriority(stepTexts)
...
252|     local expanded = {}
253|     for i = 1, #stepTexts do
254|         for j = 1, i do
255|             expanded[#expanded + 1] = {
256|                 type = D.ATTR_TYPE_MACRO,
257|                 macrotext = stepTexts[j],
258|             }
259|         end
260|     end
261|     return expanded
```

Structurally unrelated implementations. Both emit `Σ(1..N)` entries in concatenated increasing prefixes — for N=3, `[1, 1, 2, 1, 2, 3]`. Independent code, identical observable behavior: behavior/design replication, not text copying, which is exactly the claim this exhibit makes.

## A2 — The lock, and the workaround written around it

**GSE states the protective intent in a comment** — `GSE/API/Storage.lua:9`:

```lua
9| -- internals exposed, to deny in-memory scraping by third-party addons. But user
```

**GRIP documents routing around it** — `Import/LegacyMigrate.lua:92-99`:

```lua
 92|     -- Source access: newer source builds keep the runtime table private
 93|     -- (file-local addon table, no global). Bind the runtime library when
 94|     -- the global exists; otherwise migrate straight from SavedVariables,
 95|     -- which the source keeps in sync on every storage write.
 96|     local lib = _G.GSE and _G.GSE.Library or nil
 97|     if not lib and not _G.GSESequences then
 98|         return false, L["GEMS_MIGRATE_EMPTY"]
 99|     end
```

Three things this shows on its face:

1. **Knowledge.** "newer source builds keep the runtime table private" is a description of GSE's privatisation — GRIP's author knew the table had been closed.
2. **The fallback exists because of it.** When the private-table path is unavailable, GRIP reads GSE's raw SavedVariables instead. The workaround is conditioned on the lock.
3. **The comment avoids naming GSE while the code names it explicitly.** The prose says "the source"; line 96–97 reads `_G.GSE`, `_G.GSE.Library` and `_G.GSESequences` by name. The euphemism in the comment is not matched by the code.

*(For counsel: SavedVariables are plaintext on the user's own disk, so this is not classic DRM circumvention and no §1201 theory is advanced. The relevance is knowledge and non-consent — GSE said "no scraping," GRIP built the bypass.)*

## A3 — Owner identity: GSE binds it, GRIP blanks it

**GSE clears `PlatformID` deliberately on copy, and says why** — `GSE/API/Storage.lua:704-745`:

```lua
704| -- brand-new sequence: it is given a fresh GSE.Tools identity (PlatformID is
705| -- cleared) so the copy and the original never resolve to the same server
706| -- record.
...
743|     -- PlatformID; otherwise the copy and the original would share one server
745|     clone.MetaData.PlatformID = nil
```

That is the point of the field: it ties a sequence to one creator's server record, and GSE goes out of its way to keep a duplicate from inheriting it.

**GRIP blanks the origin identity on GSE-legacy import** — `Import/LegacyImport.lua:870-874`:

```lua
870|         seqData.originalAuthor = seqData.author or "Unknown (GSE legacy)"
871|         seqData.originalAuthorIdentity = ""
872|         seqData.originalAuthorRealm = ""
873|         seqData.originalAuthorBattleTag = nil
874|         seqData.originalCreatedAt = 0
```

## A4 — Mechanical checks anyone can rerun

Run against the v2.3.5 archive hashed above (unpack it, or grep the archive directly):

| Token | Occurrences in GRIP v2.3.5 | Reading |
|---|---|---|
| `PlatformID` | **0** | GSE's owner-identity field does not exist anywhere in GRIP's 182 Lua files. |
| `HelpURL` | **0** | GSE's `gse.tools` owner link is absent. |
| `gse.tools` | **0** | No reference to the owner-listing domain survives anywhere in the tree. |
| `Checksum` | 30 | **Not zero, and the claim is not that it is.** GRIP has its own checksum concept. The finding is narrower: GSE's *Ed25519 server-signed* `Checksum` is not carried into what GRIP exports or shares. Do not overstate this row. |

```bash
# from evidence/ in this repository - the cited sources, extracted unmodified
grep -ric "PlatformID" cited-source/v2.3.5/ | grep -v ':0$' || echo "PlatformID: zero occurrences"
grep -ric "HelpURL"    cited-source/v2.3.5/ | grep -v ':0$' || echo "HelpURL: zero occurrences"
```

*The counts above were originally taken across all 182 Lua files of the full v2.3.5 package. The
full package is no longer published here (`PROVENANCE.md`, 2026-08-26 addendum); `cited-source/`
carries the files this exhibit cites. Its SHA-256 remains in `SHA256SUMS.txt` for anyone holding
a copy of the original archive.*

Confirmed on 2026-07-29 against the hashed archive. `PlatformID`, `HelpURL` and `gse.tools` each returned zero across all 182 Lua files.

### Re-verified against the current release, v2.3.16 (2026-07-29)

The analysis above pins to **v2.3.5**. The claims were re-run against the current release to confirm the complaint is about live behaviour, not a fixed historical build.

**`GRIP-EMS-v2.3.16.zip` — SHA-256 `5c1499cf695b1c82710177566b9ae5eab7c8ccd2edb802378d21d0feff39464e`, 3,013,594 bytes, 244 entries, 198 `.lua` files, `.toc` reports `v2.3.16`.**

| Check | v2.3.5 | v2.3.16 |
|---|---|---|
| `PlatformID` occurrences | 0 | **0** |
| `HelpURL` occurrences | 0 | **0** |
| `gse.tools` occurrences | 0 | **0** |
| Reads GSE's internal globals | yes | **yes** — `GSESequences` ×9, `GSE.Library` ×1 |

**Two citations land on identical line numbers in both releases**, eleven versions apart — so the exhibit's references are current, not stale:

- `Engine/StepFunctions.lua:248-262` — `SF:ExpandPriority`, the nested `for i / for j` double loop, character-for-character the same code at the same lines (file is 505 lines in both).
- `Import/LegacyMigrate.lua:92-99` — the documented lock workaround (*"newer source builds keep the runtime table private … otherwise migrate straight from SavedVariables"*), same lines, same wording, still reading `_G.GSE`, `_G.GSE.Library` and `_G.GSESequences` by name.

**One citation moved and should be renumbered when quoting v2.3.16.** `Import/LegacyImport.lua` grew from ~900 to **2,396** lines. The GSE-legacy identity blanking previously cited at `857-872` is now at **`921-927`**, and it is unchanged in substance:

```lua
921|         seqData.originalAuthor = seqData.author or "Unknown (GSE legacy)"
922|         seqData.originalAuthorIdentity = ""
923|         seqData.originalAuthorRealm = ""
924|         seqData.originalAuthorBattleTag = nil
925|         seqData.originalCreatedAt = 0
926|         seqData.originalSignature = ""
927|         seqData.modifierChain = {}
```

The same file now also carries `LI.ApplyForgeProvenance` (line 117), which blanks the identical identity fields for "GRIP Forge" content — i.e. the blanking pattern has been generalised, not withdrawn. `provenanceSource = "gse-legacy"` is still stamped at line 928.

**Bottom line:** every element of the claim is present in the release currently being distributed. Nothing here has been remediated in the eleven versions since v2.3.5.

