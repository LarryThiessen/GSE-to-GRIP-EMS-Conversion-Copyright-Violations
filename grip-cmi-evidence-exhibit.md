# Evidence Exhibit — Unauthorized import, identifier-stripping, and redistribution of licensed WoW macro sequences by GRIP-EMS

**Prepared by:** Larry Thiessen (ScaryLarryGames / "SLG") — author of the SLG-Sequences GSE sequence sets
**Subject addon:** GRIP – Enhanced Macro Sequencer ("GRIP-EMS"), by *Sataana* (MrSataana / JesperLive), CurseForge project ID 1489414
**Related addon:** GSE – Sequences, Variables, Macros (GnomeSequencer-Enhanced), by TimothyLuke
**Versions examined:** GRIP-EMS **v2.3.5** (built 2026-07-03, current release — the operative version for this complaint), with v1.0.4 (2026-03-21) and v1.9.1 (2026-04-12) examined to show the behaviour is long-standing; all downloaded from CurseForge. GSE addon source: public (GitHub `TimothyLuke/GSE-Advanced-Macro-Compiler`).
**Date:** 2026-07-08

> **Nature of this document.** This is a factual, source-cited technical record. Every claim below is a line you can read in the shipped, un-obfuscated Lua of the public CurseForge downloads — no decompilation. I am a GSE sequence author, an interested party; do not take my characterization on faith — the reproduction steps at the end let any reviewer confirm each line independently. Legal-characterization sections are my good-faith basis for complaint, not a legal opinion; I am not a lawyer.

---

## 1. Summary of the claim

I and other creators have authored GSE macro sequences for years — a large share distributed **privately**, only to supporters/subscribers, and licensed for **personal use with no redistribution**. The GSE ecosystem binds each unique sequence to an author-owned identity (a `PlatformID` that resolves to the author's GSE.Tools account record).

GRIP-EMS contains a migration subsystem that, on the end-user's machine:

1. **Bulk-copies every GSE sequence the user has installed** — including privately-distributed, author-locked ones — by reading GSE's in-memory library and on-disk save data;
2. **Records that the material is GSE-authored** (it reads and stores the source GSE version), i.e. it acts with knowledge of origin;
3. **Discards the author-owned `PlatformID`** identifier during conversion, keeping only a free-text author label; and
4. **Re-exports and peer-to-peer shares** the converted sequence with **no provenance, license, or redistribution check**.

The net effect is that licensed, author-locked, often private creative work is converted into free-floating GRIP sequences, stripped of the identifier that binds them to their author's account, and made freely redistributable — outside the controlled distribution the license depends on.

---

## 2. The works and their license

- **Works:** original GSE macro sequences authored by me under the "SLG-Sequences" name (macro step logic, ordering, variables, metadata).
- **Distribution:** ~80% distributed **privately** to supporters/subscribers, not published openly.
- **License:** custom personal-use license — **no redistribution, no commercial use** (full text at Appendix B).
- **Public notice:** every one of my sequence projects on CurseForge is published with its **Project License set to "All Rights Reserved,"** whose "View full license" is the SLG-Sequences license (Appendix B). The no-redistribution terms are therefore publicly posted on each project page — constructive notice to anyone building an import/conversion tool against them.
  - *Note on the separate CurseForge "Project distribution → Allow distribution to 3rd party" toggle:* that setting governs whether third-party **download clients/launchers** (e.g. app managers) may serve the addon **zip**; it is not a copyright license and does not authorize any party to extract, convert, re-encode, or redistribute the **sequence content** contrary to the All-Rights-Reserved license above.

*(Each affected creator asserting this holds their own copyright in their own sequences; this exhibit is written from my position and is reusable by other GSE authors for their works.)*

---

## 3. Finding 1 — GSE binds each sequence to an author-owned identity (`PlatformID`)

GSE stamps each unique sequence with a `PlatformID` — described in GSE's own source as the sequence's **"GSE.Tools identity"**, a server-record key. It is preserved across renames and deliberately **cleared on duplication** so that no two sequences resolve to the same server record.

**GSE `GSE/API/Storage.lua` (duplicate path):**
```lua
-- brand-new sequence: it is given a fresh GSE.Tools identity (PlatformID is
-- cleared) so the copy and the original never resolve to the same server record
...
-- A duplicate must mint its own GSE.Tools record, so clear the inherited
-- PlatformID; otherwise the copy and the original would share one server id
clone.MetaData.PlatformID = nil                       -- Storage.lua ~L731
```
- Rename preserves it: `GSE/API/Storage.lua` L601–604 ("Rename … preserving its PlatformID").
- Stored on the sequence: `GSE/API/SequenceDelta.lua` L298 `obj.MetaData.PlatformID = pid`; L339 `local pid = meta.PlatformID or obj.PlatformID`.
- The `PlatformID` is a stable, server-resolved record key. GSE's own delta/fork code keys each sequence's stored record on its `PlatformID` and carries the **upstream (original) PlatformID** so the record resolves back to its source on the server:
```lua
-- GSE/API/SequenceDelta.lua  (StoreDeltaFork)
-- src = the upstream (original) platformId, so the delta is self-describing:
-- the Mod reconstructs from `b`, the website/server resolve `src` and apply.   -- L328-329
local entry = { b = element.base, d = element.delta, t = ..., src = element.upstreamId }
GSEDeltas[pid] = entry                                                          -- L331
```
That is: each unique sequence has a persistent identity that ties it to its originating record — an author/work identifier, not a value the end user sets.

**Why the identifier exists (and when):** GSE introduced `PlatformID` on **2026-04-25** as part of its **GSE.Tools Companion / cloud-sync system** (issue #1893). Its purpose is to give every sequence a single stable server-record identity so that a creator's sequences sync to, and remain owned by, that creator's GSE.Tools account — and so a copy never collides with the original. It is, by design, the field that binds a sequence to its author of record.

**Timeline (so the version citations are unambiguous):** `PlatformID` did not exist in GSE before 2026-04-25. Accordingly, the operative conduct here is by **current GRIP (v2.3.5, 2026-07-03)** operating on **current GSE** sequences that now carry a `PlatformID`. GRIP's import/export handling has been byte-for-byte the same behaviour since v1.0.4, but only from GSE's 2026-04-25 build onward is there a `PlatformID` present for GRIP to omit. All "drops PlatformID" citations below are to GRIP **v2.3.5**.

**Plain English:** `PlatformID` is copyright-management-type information — a unique identifier tying each sequence to its author's account/ownership record.

---

## 4. Finding 2 — GRIP bulk-imports the user's installed GSE sequences

GRIP's migration (`Import/GSEMigrate.lua` in v1.0.4; renamed `Import/LegacyMigrate.lua` in v1.9.1) reads GSE's **live in-memory library**, force-decompressing every class, and falls back to reading GSE's **on-disk SavedVariables** (`GSE.lua`).

**GRIP `Import/LegacyMigrate.lua` (v2.3.5):**
```lua
local lib = _G.GSE and _G.GSE.Library or nil                          -- L96   reach into GSE runtime
if not lib and not _G.GSESequences then ... end                       -- L97
if lib and _G.GSE.EnsureClassLoaded then
    for classID = 0, 13 do pcall(_G.GSE.EnsureClassLoaded, classID) end -- L102-104 force-decompress ALL classes
end
...
for classID = 0, 13 do                                                -- L139  walk every sequence
    ... for seqName, seqObj in pairs(lib[classID]) ...
-- disk fallback:
if results.count == 0 and results.skipped == 0 and _G.GSESequences then -- L193  read GSE.lua directly
    for seqName, rawData in pairs(GSESequences[classID]) do            -- L197
```

**Plain English:** GRIP copies *every* sequence the user has in GSE — it does not limit itself to sequences the user personally authored. Privately-distributed, supporter-only sequences a user received are included.

---

## 5. Finding 3 — GRIP acts with knowledge that the material is GSE-authored

GRIP explicitly reads and stores the **source GSE version** of each imported sequence:

**GRIP `Import/LegacyImport.lua` (v2.3.5) L696:**
```lua
seqData.importMeta.sourceVersion = tostring(sequence.MetaData.GSEVersion)
```
(also `ImportPreview.lua` L747). GRIP therefore records, per sequence, that the content originates from GSE — establishing knowledge of origin.

---

## 6. Finding 4 — GRIP discards the author-owned `PlatformID`

On import, GRIP copies **exactly six** named fields from each GSE sequence into its own record. `PlatformID` is **not** among them, and `PlatformID` appears **nowhere** in GRIP's Lua (verified by full-tree search of v1.0.4, v1.9.1, and current v2.3.5: zero references).

**GRIP `Import/LegacyMigrate.lua` (v2.3.5) L170–175** (identical mapping also at L239–244 in the disk-fallback path, and unchanged since v1.0.4):
```lua
author      = seqObj.MetaData and seqObj.MetaData.Author,
description = seqObj.MetaData and seqObj.MetaData.Help,
specID      = seqObj.MetaData and seqObj.MetaData.SpecID,
updatedAt   = seqObj.MetaData and seqObj.MetaData.LastUpdated,
icon        = seqObj.Icon,
classID     = classID,
-- (no PlatformID; no GSE.Tools identity carried forward)
```

**Plain English:** GRIP keeps the human-readable author *label* but drops the machine identifier that binds the work to the author's GSE.Tools ownership record. After conversion, the sequence can no longer be resolved to its author's account.

---

## 7. Finding 5 — GRIP re-exports and shares with no provenance or redistribution guard

GRIP's export (`Import/GRIPExport.lua`, "*export and import for sharing sequences between users*") re-serializes a sequence for sharing and strips **only** locale fields — there is no `PlatformID`, no license check, no origin/redistribution gate.

**GRIP `Import/GRIPExport.lua` (v2.3.5) `PrepareExportVersions` L31–34:**
```lua
-- Strip storage-only locale fields (not part of transport format)
verCopy.taggedSteps      = nil
verCopy.taggedKeyPress   = nil
verCopy.taggedKeyRelease = nil
verCopy.stepsLocale      = nil
-- (everything else, including the copied content, is emitted as a !GRIP1! share string)
```
Peer-to-peer distribution: `Engine/Transmission.lua` ("*Player-to-player sequence sharing via AceComm-3.0*"). Its only gate is a manual per-player **spam block list** (`blockedPlayers`) — nothing keyed on the content's author, license, or GSE origin.

**Plain English:** once a licensed GSE sequence is imported, GRIP will re-share it to any player, with the author-ownership identifier already removed.

---

## 7a. Version history — the omission is present in every GRIP release (64 of 64)

Every public GRIP-EMS release from **v1.0.4 (2026-03-21)** through **v2.3.5 (2026-07-03)** — 64 files — was downloaded from CurseForge and its Lua scanned. The result is uniform across all 64:

- **Reads GSE's data on import:** YES in every release (`GSE.Library` / `GSESequences`).
- **`PlatformID` references anywhere in the addon:** **zero** in every release.
- **Import field set:** the same fixed list (`author`, `description`, `specID`, `updatedAt`, `icon`, `classID`) in every release — `PlatformID` never carried.

GSE introduced `PlatformID` on **2026-04-25** (§3). The first GRIP release after that date is **v2.0.0 (2026-05-02)**. Significance:

| Phase | GRIP releases | GSE has PlatformID? | Effect of GRIP's constant omission |
|---|---|---|---|
| Pre-ID | v1.0.4 → v1.9.10 (2026-03-21 → 04-23) | no | latent — no identifier exists to drop |
| **Post-ID** | **v2.0.0 → v2.3.5 (2026-05-02 → 07-03)** | **yes** | **active removal of a present author identifier** |

The omission is therefore **structural and constant** — not a regression or a change slipped into one build. Every GRIP version handles the field identically; GSE's addition of `PlatformID` on 2026-04-25 is what turns a constant omission into ongoing removal of a now-present CMI identifier. Full per-version record (version, date, whether GSE carried a PlatformID at that time, GRIP's handling): **Appendix D / `grip_version_scan.csv`**.

## 8. Derived before / after (reconstructed from the functions above; no live processing of third-party work)

**A GSE sequence as stored (decoded `GSESequences` entry):**
```
MetaData = {
    Name       = "SLG_Feral_ST",
    Author     = "ScaryLarryGames",
    PlatformID = "gt_9f83a1c4e7...",   <-- GSE.Tools identity, bound to author's account
    GSEVersion = "3.3.22",
    SpecID     = 103,
    Help       = "SLG single-target — supporters only, no redistribution",
    ...
},
Sequences/Actions = { ... macro step logic ... }
```

**The same sequence after GRIP import → GRIP export (`!GRIP1!` share string):**
```
{
    name       = "SLG_Feral_ST",
    author     = "ScaryLarryGames",        <-- label retained
    -- PlatformID: ABSENT (never imported by LegacyMigrate; no slot in export)
    specID     = 103,
    steps/actions = { ... same macro step logic, now redistributable ... }
}
```
The copyright-management identifier (`PlatformID`) is gone; the protected content is present and freely shareable.

---

## 9. Legal basis for complaint

1. **Copyright infringement — unauthorized reproduction and distribution.** The sequences are original creative works licensed for personal use with **no redistribution**. GRIP reproduces them into its own format and provides the means to redistribute them (export + P2P), outside the license.
2. **DMCA §1202 — removal of copyright management information (CMI).** GRIP, with knowledge that the material is GSE-authored (Finding 3), strips the author-bound `PlatformID` identifier (Finding 4) and distributes the works with that CMI removed (Finding 5). Intentional removal/alteration of CMI, and distribution of works knowing CMI was removed, to induce/enable/conceal infringement, is prohibited under 17 U.S.C. §1202(b). The SLG-Sequences license independently forbids removing or altering "any author or attribution notices" (Appendix B, clause 2(d)).

**What is *not* claimed (scope and honesty):**
- **This is not a source-code-copying claim.** An independent line-level diff of GRIP vs GSE shows only generic WoW/Ace3 boilerplate in common — GRIP's *program code* is not copied from GSE. This complaint is solely about GRIP's handling of **sequence content authored by third parties**.
- **This is not a §1201 anti-circumvention claim.** `PlatformID` is an identity/sync key, not an access-control or encryption measure; GRIP does not defeat encryption. The claim is CMI **removal** (§1202), not circumvention.
- **A user converting their own installed copy for personal use** is not the target. The actionable conduct is (a) ingesting **other creators'** licensed/gated content and (b) enabling its **redistribution** with the author identifier removed.
- GRIP **retains the author's free-text label**, so this is not a claim of plagiarism/passing-off. It is a claim of unauthorized redistribution + CMI removal.

---

## 10. How a reviewer can verify every line

1. Download GRIP-EMS from CurseForge (`grip-enhanced-macro-sequencer`) and unzip. Lua ships in plain text.
2. Open `Import/LegacyMigrate.lua` (or `GSEMigrate.lua` in ≤v1.0.x): confirm the `GSE.Library` / `GSESequences` reads (§4) and the six-field `opts` mapping with no `PlatformID` (§6).
3. Open `Import/LegacyImport.lua`: confirm `importMeta.sourceVersion = ...MetaData.GSEVersion` (§5).
4. Open `Import/GRIPExport.lua` (`PrepareExportVersions`): confirm only locale fields are stripped and no `PlatformID` is present (§7).
5. Full-tree search the GRIP folder for `PlatformID`: confirm zero references in Lua.
6. In the GSE addon (`GSE/API/Storage.lua`, `SequenceDelta.lua`): confirm `PlatformID` is the GSE.Tools identity, preserved on rename, cleared on duplicate (§3).

---

## 11. Requested remedy

Aimed at the addon and its distribution (CurseForge / the GRIP author):

1. GRIP must **not** import or re-export sequences authored by third parties under a no-redistribution license without the author's consent; and
2. GRIP must **not** strip the author-ownership identifier (`PlatformID`) from imported content, and must **block re-export/sharing** of content imported from GSE unless the author has permitted redistribution; or
3. Failing that, removal of the infringing functionality under CurseForge's IP / project-moderation policy.

---

## Appendix A — files examined (fill in SHA-256 at filing)

- `GRIP-EMS-v2.3.5.zip` (2026-07-03, **operative version**) — SHA-256: `b50ca92e643024fdef84477b325ba0cfaa1056967a077183634d1a8218bd8d2a`
- `GRIP-EMS-v1.9.1.zip` (2026-04-12) — SHA-256: `4fa4269a89c46c61fbd3f06bfccee21a1b6ca3df1e3f5a1604114ea153cb7602`
- `GRIP-EMS-v1.0.4.zip` (2026-03-21) — SHA-256: `c3f9677d27fe89c79cbd94a93abaaade47f6291a133afd94932a86285a584cbe`
- GSE addon source — public GitHub `TimothyLuke/GSE-Advanced-Macro-Compiler`; `PlatformID` introduced 2026-04-25 (issue #1893, GSE Tools Companion sync). Cite the commit/tag current at filing.

## Appendix B — SLG-Sequences license (verbatim)

Source: `github.com/LarryThiessen/SLG-Sequences` (`LICENSE`).

```
SLG-Sequences License
Copyright (c) 2026 Larry A. Thiessen ("ScaryLarryGames"). All Rights Reserved.

1. GRANT. You are granted a personal, non-exclusive, non-transferable, revocable
   license to download and use this software and its sequence/macro content
   ("the Work") for your own personal, non-commercial use in World of Warcraft,
   including modifying it for your own personal use.

2. RESTRICTIONS. You may NOT, without the prior written permission of the author:
   (a) redistribute, re-host, re-upload, mirror, or publish the Work or any part
       of it on any website, platform, or service (CurseForge, Wago, etc.);
   (b) distribute or share modified or derivative versions of the Work;
   (c) sell, license, sublicense, rent, or otherwise commercialize the Work or
       any part of it, or include it in any paid or monetized product;
   (d) remove or alter this license or any author or attribution notices.

3. DISTRIBUTION. Official distribution of the Work is performed solely by the
   author (e.g., via the author's CurseForge and GSE.Tools pages). Subscriber and
   other paid content remains the property of the author and may not be shared.

4. RESERVATION. All rights not expressly granted above are reserved by the author.

5. NO WARRANTY. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
   EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
   MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO
   EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES
   OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
   ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
   DEALINGS IN THE SOFTWARE.
```

**Terms most directly engaged by the conduct in §4–§7:**
- **2(a)** — no redistribution/re-upload of the Work or any part → GRIP's export + P2P sharing of imported sequences.
- **2(b)** — no distribution of modified/derivative versions → GRIP re-encodes the sequence into its own `!GRIP1!` format and shares it.
- **2(d)** — no removal/alteration of author or attribution notices → GRIP drops the `PlatformID` author-identifier (the §1202 CMI point).
- **3** — subscriber/paid content remains the author's and may not be shared → the ~80% privately-distributed sequences.

## Appendix C — (optional) captured proof artifact

A `!GRIP1!` export string of one sequence **I authored**, showing my content present and `PlatformID` absent. *(Optional — the code in §4–§7 already establishes the mechanism; capture only with a test sequence of your own, never by processing another creator's work.)*

## Appendix D — version-by-version scan (machine-readable)

`grip_version_scan.csv` — every GRIP-EMS release v1.0.4 → v2.3.5 (64 files) downloaded from CurseForge and scanned. Columns: `version, upload_date, GSE_had_PlatformID, reads_GSE_data, platformID_refs_in_GRIP, carries_PlatformID_forward`. Result is uniform: `reads_GSE_data = yes` and `platformID_refs_in_GRIP = 0` for all 64; `carries_PlatformID_forward = NO` for all 64. Reproduce by downloading each file ID from CurseForge and running `grep -rn PlatformID` over its Lua.
