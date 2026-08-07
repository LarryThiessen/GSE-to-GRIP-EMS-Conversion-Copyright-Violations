# What changed after the complaint — GRIP-EMS v2.3.17 / v2.3.18, and LazyGrip.net

**Compiled:** 2026-08-07
**Method:** both GRIP releases published since this package's last verification were downloaded from CurseForge and searched; LazyGrip.net's published source and live endpoints were read; the platform behaviour was confirmed by the GSE.Tools operator (`companion-app/OPERATOR-STATEMENT-2026-08-07.md`). Every count below is reproducible from the same files.

**Why this exhibit exists.** Between 2026-07-30 and 2026-08-06 the GRIP-EMS addon and the LazyGrip.net website both changed in ways that bear on this complaint. One of those changes is a genuine remedial improvement and is recorded as such, in full. Another undoes it. Both go in — on the principle applied throughout this package: findings that cut against the rights holder are written down by the rights holder, with dates, rather than left for the other side to discover.

---

## 1. The releases

| Release | CurseForge file ID | Published | Size | SHA-256 |
|---|---|---|---|---|
| v2.3.16 | 8537834 | 2026-07-30 02:46:20 | 3,013,594 B | `5c1499cf695b1c82710177566b9ae5eab7c8ccd2edb802378d21d0feff39464e` |
| **v2.3.17** | **8557810** | **2026-08-01 23:37:51** | 3,047,613 B | `35299aa686e3d7cc3b45b7360db466f88b90bfec5127e5b3ccbd1c902ad26d37` |
| **v2.3.18** | **8578923** | **2026-08-04 22:46:16** | 3,092,514 B | `ec590cc0f78db732739d600578b2d9dbd1fd8564fcdf9a4fc54c3c75dfcbfac9` |

v2.3.18 is the current release. v2.3.16 was the operative version cited in `grip-cmi-evidence-exhibit.md`; that exhibit's findings were re-run against both newer builds.

---

## 2. What genuinely improved — recorded in full

**GRIP v2.3.17 added a do-not-share refusal, it is properly built, and it works.**

A new function, `LI.ResolveNoRedistribute` (`Import/LegacyImport.lua`), reads a do-not-share marker off an inbound sequence and stores it as `seqData.noRedistribute`. It resolves three inbound shapes in precedence order: an explicit `noRedistribute`, GSE's mixed-case `MetaData.noExport`, and the lowercase `noExport` of a converted payload.

It is then **enforced at nine call sites**, not merely displayed:

- **Export** — `Import/GRIPExport.lua`, four sites covering the single, collection, provider and text rails. The refusal sits ahead of construction, and their own comment says why: *"Do-not-share refusal, ahead of every build step: no payload table, no encoded string, nothing for a caller to salvage. This is the choke point the P2P send path funnels through as well."*
- **Peer-to-peer sharing** — `Engine/Transmission.lua`, five sites, covering the send path, list building and inbound requests.
- **Import preview** — the flag is surfaced and badged before the user commits, not only after storage.

Absent from v2.3.5 and v2.3.16 — zero references in either — and present in v2.3.17 and v2.3.18 at 15 references each.

**And the marker it reads is really applied.** The GSE addon never writes `noExport` (13 reads, 0 writes, in both the shipped build and the full source). GSE.Tools does. Per the platform operator, 2026-08-07:

> everyone who is not the original authro gets a dont export stamp on it

So every copy of the rights holder's work held by someone who is not its author carries the stamp. Traced end to end on the in-game path:

1. GSE.Tools stamps `MetaData.noExport` on the non-owner's copy.
2. `Import/LegacyMigrate.lua` walks GSE's library and passes the **raw sequence object, MetaData intact**, to `LI.ProcessSequence(seqName, sequence, results, opts)`.
3. That function calls `LI.ResolveNoRedistribute(sequence)`, which reads `sequence.MetaData.noExport` and returns true.
4. `seqData.noRedistribute` is set.
5. `GE.IsNoRedistribute` refuses at all nine sites.

**On the in-game migrate path the protection works.** A third party who migrates a GSE library containing the rights holder's sequences into GRIP v2.3.17 or later cannot re-export or re-share them. This is a real remedial improvement, it is close in shape to the first remedy this complaint asked for, and this package does not describe it as cosmetic.

---

## 3. And their own website removes the marker it depends on

The protection in §2 lives or dies on one field surviving. Every module of the converter published at `github.com/lazygrip/lazygrip-gg` was searched for it:

| Module | `noExport` / `noRedistribute` references |
|---|---|
| `src/lib/workshop/gseToGrip.ts` | **0** |
| `src/lib/workshop/gseDecoder.ts` | **0** |
| `src/lib/workshop/emsEncoder.ts` | **0** |
| `src/lib/workshop/gripEnvelope.ts` | **0** |
| `src/lib/workshop/gripExportEnrich.ts` | **0** |
| `src/app/api/workshop/decode/route.ts` | **0** |

**Zero, in all of them.**

That same converter was amended on 2026-07-30 (commit `8d541bc`, `slowdog-dev`) specifically to carry `platformId`, `helpUrl`, `checksum` and `gseVersion` through conversion. Four fields were added that day. **The one field that stops redistribution was not among them, and is still not carried.**

A stamped sequence put through that converter emerges unstamped. GRIP then exports and shares the result normally, because the refusal reads a field that is no longer there.

### The consequence, stated plainly

> **The addon refuses to redistribute a stamped sequence. Their website's converter removes the stamp.**

Two doors into the same addon, behaving in opposite ways:

| Route | Stamp survives? | GRIP's refusal fires? |
|---|---|---|
| In-game **Migrate** | yes | **yes — blocked** |
| **LazyGrip.net** conversion | **no** | no — exports and shares freely |

The convert page was disconnected from the Workshop UI on 2026-08-06 (`ce4b75a`), but the same conversion remains reachable through the Build tool's import endpoint — `/api/workshop/import` → `importToBuilderModel` → `convertDecodedGSEToGRIP` — which has no `noExport` handling either. See §5.

*No motive is asserted for the omission. The counts are recorded; readers may draw their own conclusions.*

### 3.1 Both markers are artifacts of one distribution channel. The licence is not.

Everything in §2 and §3 concerns two fields — `PlatformID` and `noExport` — and **both are applied by GSE.Tools.** Neither is written by the GSE addon. Neither exists on a sequence that has not passed through that platform.

Which exposes the limit of the whole scheme:

> **An author can write a sequence, export it as a `!GSE3!` string, and hand it to a supporter without the platform ever touching it. That sequence carries no `PlatformID` and no do-not-share stamp — and it is still that author's work, still under whatever licence they published it with.**

GRIP converts and redistributes it regardless, because **there is no licence check anywhere in its import or export path.** Not in `LegacyMigrate.lua`, not in `LegacyImport.lua`, not in `GRIPExport.lua`, not in `Transmission.lua`. The only gates that exist are the do-not-share marker added in v2.3.17 and a manual per-player spam block list. Neither reads a licence; neither knows one exists.

So the two mechanisms GRIP has — the identifier it removes, and the marker it now honours — both depend on the platform having stamped the work first. **Copyright does not.**

**The permission instrument is the licence.** Every one of the rights holder's sequence projects is published on CurseForge with its Project License set to **All Rights Reserved**, whose text forbids redistribution, re-hosting, distribution of derivative versions, and removal of author or attribution notices. That licence is posted publicly on each project page — constructive notice to anyone building an import or conversion tool against it. It binds whether or not the work was ever synced, whether or not any field is present, and whether or not any addon chooses to look.

So the position is not "GRIP failed to honour a do-not-share flag," and it is not "GRIP removed an identifier." Those are how the breach is *evidenced*. The breach itself is simpler:

> An All-Rights-Reserved work is reproduced into another addon's format and made redistributable, without the author's permission and without any check for one. The identifier's removal and the marker's omission are aggravating facts. **Neither is what makes the conduct unlawful, and the absence of both is not a defence.**

This is also why the remedy in §6 is framed on the identifier rather than the marker: the identifier is present in GRIP's own payload today and is the cheapest thing for them to act on. It is not, and is not offered as, the limit of the rights holder's claim.

---

## 4. What did not change

Re-running this package's own checks against the current release, **v2.3.18**:

| Check | v2.3.16 | v2.3.18 |
|---|---|---|
| `PlatformID` / `platformId` references | 0 | **0** |
| `HelpURL` / `helpUrl` references | 0 | **0** |
| `Import/LegacyMigrate.lua` header date | 2026-07-26 | **2026-07-26 (unchanged)** |
| Reads `GSE.Library`, `GSESequences`, `GSEVariables`, `GSEMacros` | yes | **yes** |
| Force-loads every class via `GSE.EnsureClassLoaded` | yes | **yes** |
| Import field mapping | author, description, specID, updatedAt, icon, classID | **identical — no `PlatformID`** |
| GSE `Checksum` | copied to `importMeta.sourceChecksum`, never validated | **unchanged** |

**The reproduction and the identifier removal are present, unaltered, in the release shipping today.** The new refusal governs what happens to a sequence *after* it is inside GRIP. It does not stop the copy being made, and it does not restore the identifier.

For contrast, in GSE's own source: `PlatformID` is referenced 20 times and **written twice** — stamped when a sequence is rebuilt from the platform's record (`SequenceDelta.lua:298`), and deliberately cleared on duplication (`Storage.lua:745`) so a copy can never resolve to the original's server record. A field guarded carefully enough to be wiped on a copy is an ownership handle.

One field did move: `gseVersion` appears 6 times in v2.3.18 against 0 in v2.3.16, used to select which provenance label renders. That is a badge, not a control.

---

## 5. The website, 2026-08-06

Two commits to `lazygrip/lazygrip-gg`, nine minutes apart, both by `slowdog-dev`.

**19:59:42 — `4bf6979` "Rename GSE references to legacy program in Workshop UI."** Visible copy and error messages across the decode, convert and build pages and their API routes now read "legacy program" instead of "GSE." Their own commit message states the limit of it: *"Format detection, decoding, and conversion logic unchanged."*

**20:08:32 — `ce4b75a` "Remove Convert to GRIP from Workshop."** Verified live on 2026-08-07: `/workshop/convert` redirects to `/workshop`, and `POST /api/workshop/convert` returns 404. Their commit message: *"Converter logic unchanged and can be restored."* The handler left in place says the same:

```ts
// Disconnected from the Workshop UI. The converter itself
// (convertGSEExportToGRIP in @/lib/workshop/index) is untouched
// and can be wired back in by restoring the body of this handler.
```

### 5.1 The conversion is still reachable on the same site

`/workshop/build` is live, and its import endpoint `/api/workshop/import` is live. That endpoint calls `importToBuilderModel`, which contains:

```ts
if (format === "GSE3") {
  const decodedGse = decodeGSEExport(code);
  const converted = convertDecodedGSEToGRIP(decodedGse);
```

`convertDecodedGSEToGRIP` is exported from the same unchanged `gseToGrip.ts` module as the disconnected `convertGSEExportToGRIP`. **Pasting a `!GSE3!` string into the Build tool reaches the same conversion by a different route** — and, per §3, that route drops the do-not-share stamp.

*Basis: their published source and live HTTP status codes. **Not runtime-verified** — no string was submitted to their service, because their terms forbid running tools against the site. See §7.*

### 5.2 And the converter is published for anyone to run

`lazygrip/lazygrip-gg` is a **public repository under the MIT licence** (verified 2026-08-01 and 2026-08-07), and `src/lib/workshop/gseToGrip.ts` is present on `main`. MIT expressly permits anyone to copy, modify, run and redistribute it. Removing the page removed a button from one website; it did not remove the capability, there or anywhere else.

**On sequence, so this is not overstated:** the repository was created 2026-04-30, and this package can confirm it was public and MIT-licensed **as at 2026-08-01**. GitHub does not expose when a repository's visibility changed, so this exhibit does **not** claim the code was published in response to anything. It claims only that the code was public before the page was removed and remained public after.

### 5.3 The licence asymmetry

Stated once, as a fact about two licence choices and nothing more: the conversion tool is published under **MIT**, the most permissive licence in common use. The material it converts is published under **All Rights Reserved**.

---

## 6. What this means for the remedy

The remedy in `curseforge-complaint-final.md` §6 asks CurseForge to require GRIP to "gate or remove the GSE-import and re-export/share functionality." §2 shows GRIP has now built exactly that machinery — a refusal ahead of construction, covering every export rail and the P2P path — and §3 shows their own website removes the field it keys on.

So the remedy can be stated far more precisely, in a form a reviewer can evaluate in seconds:

> **If an imported or converted sequence carries a GSE.Tools `PlatformID`, GRIP must not export, share or redistribute it without the owner's permission — and the LazyGrip.net converter must not remove the do-not-share marker it is given.**

Note what this does **not** ask for: it does not ask GRIP to build a permissions system. Both halves already exist.

1. **The identifier is already in their own payload.** Since `8d541bc` (2026-07-30) the converter deliberately writes `platformId` into the GRIP payload. The addon references that field **zero times**. The data arrives and nothing reads it.
2. **The enforcement point already exists.** `GE.IsNoRedistribute` is called at nine sites and refuses before anything is built. A `PlatformID` check would sit in the same places.
3. **The converter already carries four other GSE fields.** Adding a fifth is the same one-line pattern used on 2026-07-30 for `platformId`, `helpUrl`, `checksum` and `gseVersion`.
4. **It is verifiable.** "Gate the import functionality" is arguable and hard to check. "Refuse when the ID is present, and stop stripping the marker" is either implemented or it is not.
5. **It needs nothing from anyone else.** It does not depend on GSE adding anything, on the platform changing anything, or on the rights holder configuring anything. The identifier, the marker and the published All-Rights-Reserved licence all already exist.

---

## 7. Open, and honest limits

**Open for the rights holder:**

1. Verify §5.1 in a browser as an ordinary user — paste a `!GSE3!` string into the Build tool and record whether it returns a converted result. That turns an inference from source into a screenshot. *(Use a sequence of the rights holder's own. Do not put another author's work through it.)*
2. The GSE.Tools fork-approval documentation already requested from Timothy Luke (see `RIGHTS-HOLDER-STATEMENT-2026-08-01.md`).

**Not claimed:**

- **No motive is asserted** for any change recorded here, including the converter's omission of `noExport`. The dates, the commit messages and the counts are the record.
- It is **not** claimed that the do-not-share gate is cosmetic or made in bad faith. It is properly constructed, correctly enforced, and it works on the in-game path.
- It is **not** claimed that the repository was made public in response to this complaint. See §5.2.
- §5.1 rests on published source and HTTP status codes, not on a submitted string.

**Corrections recorded, not quietly amended:**

- An earlier working analysis in this package concluded that GRIP's do-not-share gate "will almost never fire," reasoning that nothing in GSE writes `noExport`. **That was wrong.** The addon does not write it; the platform does, on every non-owner copy, as the operator has now confirmed. The corrected finding is narrower and better evidenced: the gate is real and works on the migrate path, and it is defeated by the operators' own website on the conversion path.
- This package's earlier finding that the LazyGrip converter strips `PlatformID`, `HelpURL` and `Checksum` was accurate as at 2026-07-12 and ceased to be accurate on 2026-07-30, as recorded in `LAZYGRIP-OPERATOR-AND-CONVERTER-PROVENANCE.md` §5. Nothing here revives it. The website now carries those four fields; the addon still does not read them; and the field that would actually stop redistribution is still not carried.
