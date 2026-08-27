# Provenance — the GRIP-EMS release archives

Why seven `.zip` files sit in an evidence repo, where they came from, and how a third party can check them. Six are GRIP-EMS releases; one is GSE itself, so the GSE-side citations can be checked here too.

## What they are

Unmodified GRIP-EMS release packages as distributed by CurseForge, retained because **every code citation in the exhibits points into them**. GRIP-EMS is not published on any public source host, so without these archives no file:line claim in this package can be verified by a reader.

| Archive | CurseForge file ID | CF upload date | Size | SHA-256 |
|---|---|---|---|---|
| `GRIP-EMS-v1.0.4.zip` | `7791035` | 2026-03-21 | 343,881 B | `c3f9677d27fe89c79cbd94a93abaaade47f6291a133afd94932a86285a584cbe` |
| `GRIP-EMS-v1.9.1.zip` | `7918661` | 2026-04-12 | 946,584 B | `4fa4269a89c46c61fbd3f06bfccee21a1b6ca3df1e3f5a1604114ea153cb7602` |
| `GRIP-EMS-v2.3.5.zip` | `8364957` | 2026-07-03 | 2,652,665 B | `b50ca92e643024fdef84477b325ba0cfaa1056967a077183634d1a8218bd8d2a` |
| `GRIP-EMS-v2.3.16.zip` | `8537834` | 2026-07-30 | 3,013,594 B | `5c1499cf695b1c82710177566b9ae5eab7c8ccd2edb802378d21d0feff39464e` |
| `GRIP-EMS-v2.3.17.zip` | `8557810` | 2026-08-01 | 3,047,613 B | `35299aa686e3d7cc3b45b7360db466f88b90bfec5127e5b3ccbd1c902ad26d37` |
| `GRIP-EMS-v2.3.18.zip` | `8578923` | 2026-08-04 | 3,092,514 B | `ec590cc0f78db732739d600578b2d9dbd1fd8564fcdf9a4fc54c3c75dfcbfac9` |
| `GRIP-EMS-v2.4.6.zip` | *(not a CurseForge file - see note)* | 2026-08-17 | 3,338,043 B | `56a02b2b6138c030bed24a2bdf5ddc3192fe63daa670ad1c2d5432b9f22ea004` |
| `GRIP-EMS-v2.4.7.zip` | *(not a CurseForge file - see note)* | 2026-08 | 3,338,245 B | `93bdbe66555665476bcfee7ade1e60975e2d5d3eab140db27394766fb936cf72` |
| `GRIP-EMS-v2.4.8.zip` | *(back on CurseForge - see note)* | 2026-08-25 | 3,431,019 B | `33410ad5630787100b364455d4ddd207c88e453a55125b1a8bde680d67f5cbff` |
| `GSE-3.3.22.zip` | *(GSE project, not GRIP)* | — | 2,553,456 B | `24a12424632f1a6e2e1298af1871308e0ef36675a98462fc01a200106e52dae9` |

Hashes are also in `SHA256SUMS.txt`. Source project: CurseForge project **1489414**, `grip-enhanced-macro-sequencer`, author `sirsataana`.

- **v2.3.17** — published 2026-08-01, the day the copyright claim was filed. **The release that introduced the do-not-share refusal** (`LI.ResolveNoRedistribute`, enforced at nine sites). Retained because it dates that change.
- **v2.3.18** — published 2026-08-04, **the current release**. Retained to show the conduct is ongoing: `PlatformID` and `HelpURL` still appear zero times, and the migrate path is unchanged.
- **v2.4.6** — **the only archive here not sourced from CurseForge.** CurseForge removed the
  project on 2026-08-20 (see `takedown-2026-08-20/`), so this build was downloaded by the rights
  holder from **Wago Addons**, `https://addons.wago.io/addons/grip-ems`, on **2026-08-20**. Its
  internal file dates are 2026-08-17.

  **Provenance is corroborated, not assumed.** A copy of the same build reached the rights holder
  separately, from an individual rather than a platform. The two were compared: a full recursive
  diff returned **zero differing entries** across all 260 files, and the packaging-independent
  content hash of both is `b2dc61d0e28be6e0e6df88723c01b8c91f885d988865143dd83093fca0ac3d25`. The
  outer zip hashes differ only because the hand-passed copy was re-zipped (different timestamps
  and entry order). **The archive retained here is the one downloaded from Wago Addons**; the
  hand-passed copy was deleted and never entered this tree.

  Retained because it is the build cited in the Wago DMCA notice of 2026-08-20 and in
  `POST-COMPLAINT-CHANGES-2026-08-07.md`: it shows the conduct continuing eight releases and two
  weeks after the do-not-share gate was added, with `PlatformID` and `HelpURL` still at zero
  references and `LegacyMigrate.lua` re-dated but functionally unchanged.

- **v2.4.7** — downloaded by the rights holder **directly from Wago Addons**
  (`https://addons.wago.io/addons/grip-ems`). Like v2.4.6, not a CurseForge file: the CurseForge
  listing was removed on 2026-08-20.

  **Retained because of what it does not contain.** Against v2.4.6 it changes **78 lines across
  exactly two files** — 69 in the bundled third-party library `Libs/LibSharedMedia-3.0` and 9 in
  `UI/WhatsNew.lua`, the in-game changelog popup. **`Import/LegacyMigrate.lua`,
  `Import/LegacyImport.lua`, `Import/GRIPExport.lua`, `Engine/Transmission.lua` and
  `Engine/Identity.lua` are byte-identical — zero changed lines, not even a header date.**

  `PlatformID` and `HelpURL` remain at **zero references**; licence and copyright references
  across `Import/` and `Engine/` remain at **zero**; every protective mechanism is unchanged with
  **zero deletions**. This release shipped after the CurseForge removal and after the Wago DMCA
  notice of 2026-08-20, and the identifier handling was not revisited.

- **v2.4.8** — the project's most recent release, back on **CurseForge** after the
  2026-08-20 removal. Downloaded by the rights holder directly from CurseForge.

  **This release contains a genuine, well-engineered fix, and it is recorded here in full.**
  Fork, save and rename were previously dropping the do-not-share flag on copy — a sequence
  marked do-not-share became shareable simply by being duplicated locally. That is now fixed at
  all four rebuild sites via a single tracked field list, with a structural test that fails CI if
  a future sharing field is added without being carried everywhere
  (`Test/test_rebuild_carry_parity.lua`).

  **A new, separate mechanism was also added:** `GE.IsLocallyAuthored` / `GE.NeedsAuthorConfirm`
  (`Import/GRIPExport.lua`). Any sequence whose `originalAuthorIdentity` does not match the local
  player — true of every ordinary migrated GSE sequence, since migration stamps an empty string
  — now raises a confirmation popup before it can be sent or exported. Their own comment states
  its scope precisely: *"this is a single confirm naming the author, not a refusal."*

  **It also closes the exact loophole this package's own `GRIP-BYLINE-DEFECT.md` documented.**
  The auto-claim-on-save path audited there now additionally requires `IsLocallyAuthored`, which
  is fail-closed false for any empty-identity migrated sequence. Their comment states the
  tradeoff outright: *"an unmigrated signature is a cosmetic cost; a false authorship stamp is
  not."* Verified: the byline-defect guard from v2.3.16 is present and this new condition is
  layered on top of it, not in place of it.

  **What did not change.** `PlatformID` and `HelpURL` remain at **zero references**. The new
  confirmation is a click-through prompt, not a block, for ordinary migrated content — only
  `GE.IsNoRedistribute` refuses outright, and that still keys on GSE's `noExport`, which the
  platform stamps (per the operator, `companion-app/OPERATOR-STATEMENT-2026-08-07.md`) and the
  GSE addon never writes. Nothing anywhere checks that a sequence carries an All-Rights-Reserved
  licence — the new confirmation is about *authorship*, not permission. The migrate function
  that bulk-copies out of GSE is unaffected by any of this.

  A new copyright header appears on the developer's own files (`(c) 2026 Sataana... Not licensed
  for AI or ML training`). That is a notice on his own code, not a check applied to anyone
  else's.

## Addendum — 2026-08-26: full packages withdrawn for eight releases; cited files retained

On 2026-08-26 the addon's developer, contacting the rights holder directly, pointed out that this
document's own justification for archiving full installable packages — *"anyone can still
download the same files from the same project... a third party can re-download, hash, and confirm
byte-identity with what is in this directory"* — no longer holds for eight of the nine archives
here. Checked independently and confirmed true: CurseForge, Wago Addons and WoWInterface each now
serve only the current release, **v2.4.8**. The previous releases are not available from any
distribution channel. The three CurseForge file IDs already noted as 404 above (`8537834`,
`8557810`, `8578923`) are part of that same fact, not a separate one.

He also holds a copyright in the addon itself, All Rights Reserved, and the eight withdrawn
packages each carry that licence at the archive root (verified: byte-identical, SHA-256
`17c6f6cf6d34721ef0cca4f3e9ce16d3494946065e2bba102c2390938cb3cf19`, across all eight). He did not
ask that any analysis, exhibit, correspondence, finding, or quotation be removed, and none has
been. He asked specifically that the eight full packages — v1.0.4, v1.9.1, v2.3.5, v2.3.16,
v2.3.17, v2.3.18, v2.4.6, v2.4.7 — not v2.4.8, which remains available from every platform — be
taken down, and offered to not object to any specific file being kept where an exhibit's citation
actually needs it.

**What changed:** those eight `.zip` files are removed from this repository and gitignored. They
are retained on the rights holder's own machine for the ongoing investigation, not published.
**What did not change:** every SHA-256 hash below stays, so the chain of custody is unbroken and
anyone who already has a copy can still verify it against this record. Every `FILE:LINE` citation
across every exhibit was located, and the specific source files those citations resolve into —
117 files across all eight releases — are preserved and published at `evidence/cited-source/
<version>/<path>`, in the same relative path structure the citations use. No citation in this
package is unverifiable as a result of this change.

- **v1.0.4** — first release in the scan; establishes the GSE-import path existed from the beginning.
- **v1.9.1** — mid-history control.
- **v2.3.5** — the version the exhibits cite as operative.
- **v2.3.16** — the release current as at 2026-07-29, captured that day. Retained to show the conduct is ongoing rather than historical: `PlatformID`, `HelpURL` and `gse.tools` are all absent from its 198 Lua files, and it still reads GSE's internal globals. **File ID `8537834` recorded 2026-07-31** from the file's own CurseForge page (`/files/8537834`), which lists it as `GRIP-EMS-v2.3.16.zip`, uploaded by `sirsataana` on 2026-07-30.
- **`GSE-3.3.22.zip`** — **GSE**, not GRIP. Added 2026-07-31 so that the GSE-side FILE:LINE citations in `grip-vs-gse-forensic-comparison.md` and `grip-cmi-evidence-exhibit.md` can be checked from this repository rather than requiring a separate download. This is Timothy Luke's addon, retained unmodified for evidentiary comparison only.

## Capture

- **v1.0.4, v1.9.1, v2.3.5** — downloaded from CurseForge's own file endpoints on **2026-07-12** (file timestamps 21:23 local) and committed the same day in `8332cc4`. All three returned **HTTP 200** during that scan, which produced `data/version_scan_raw.csv` (file ID and result for all 64 releases).
- **v2.3.16** — captured **2026-07-29** as the then-current release. File ID `8537834` was recorded afterwards, on 2026-07-31, from the file's own CurseForge page.
- **v2.3.17, v2.3.18, GSE-3.3.22** — captured **2026-08-01 → 2026-08-04** as each was published, so the record tracks the project release-by-release rather than sampling it once.
- No archive has been opened, repacked, or altered — every hash above is the bytes as received.
- Captured by Larry A. Thiessen ("ScaryLarryGames").

## Why the archives are here, and why that is not a problem

> **SUPERSEDED as of 2026-08-26 for eight of the nine releases — see the addendum at the top of
> this file.** The paragraph below was true when written and is retained unaltered, because the
> rule it states is the rule this package was then held to and the reason the archives came down.
> It now holds only for **v2.4.8**, which is still published on CurseForge, Wago Addons and
> WoWInterface.

**The releases remain public on CurseForge.** These copies are not a substitute for an unavailable original — anyone can still download the same files from the same project. That is a *feature* of this evidence, not a gap: a third party can re-download, hash, and confirm byte-identity with what is in this directory. Few evidence exhibits are that easy to check.

**What is not available is the source.** Per the rights holder, the GRIP-EMS author's GitHub repositories are **private**, and CurseForge distributes packaged builds only. So there is no public source tree to read or diff — the only way to examine GRIP's Lua, and therefore the only way to check a single `FILE:LINE` citation in the exhibits, is to obtain a release package and unpack it. That is precisely what these archives are, pinned to fixed hashes so the citations always resolve against the same bytes even if a future release renumbers lines. That is not hypothetical: between v2.3.5 and v2.3.16, `Import/LegacyImport.lua` grew from ~900 to 2,396 lines and one cited range moved, while `Engine/StepFunctions.lua:248-262` and `Import/LegacyMigrate.lua:92-99` stayed identical.

Keep these apart:

- **Verifiable by anyone:** that file IDs `7791035` / `7918661` / `8364957` resolve on CurseForge, that their bytes hash to the values above, that `data/version_scan_raw.csv` records all three returning HTTP 200 on 2026-07-12, and that the release currently on the project page hashes to the **v2.3.18** value (`ec590cc0…`, verified 2026-08-07).
- **On the rights holder's account:** that the author's GitHub repositories are private. Checkable, but not evidenced in this package.
- **Not claimed at all:** any motive for the repositories being private. This package does not allege one, and nothing here should be read as establishing it.

## How to verify these are genuine

**For `GRIP-EMS-v2.4.8.zip` and `GSE-3.3.22.zip`, both still published:**

1. `sha256sum -c SHA256SUMS.txt` against the archives in this directory.
2. **Re-download the same file from the platform** — v2.4.8 from CurseForge project 1489414, Wago
   Addons, or WoWInterface file 27081; GSE from its own project — hash it, and compare. The values
   must match exactly. This is the check that matters and it is available to anyone.

**For the eight withdrawn releases (v1.0.4 → v2.4.7), whose packages are no longer published here
or by any distribution channel:**

3. Their SHA-256 values remain listed above and in `SHA256SUMS.txt`. **Anyone who already holds one
   of those archives — including the addon's developer, CurseForge, or Wago — can hash their copy
   and confirm it matches what this package was built from.** That is the check that survives.
4. The specific source files this package's exhibits cite are published unmodified at
   `cited-source/<version>/<path>`, at the same relative paths the `FILE:LINE` citations use, for
   every one of the eight versions. **Every citation in every exhibit resolves against them
   directly** — no archive needed. 117 files.
5. `data/version_scan_raw.csv` records the file ID and HTTP result for all 64 releases as fetched
   on 2026-07-12, if a wider baseline is needed. Note that those CurseForge file IDs **no longer
   resolve**: CurseForge purged every pre-v2.4.8 file when it actioned this claim on 2026-08-20.
6. Any archive that fails step 1 or 2 should be treated as unreliable, not argued around.

**If you are reviewing this claim and need a complete package for a version no longer published,
ask the rights holder.** The eight archives are retained on his own machine, unmodified, with the
hashes above. They are simply not distributed from this repository.

## On browser malware warnings

A browser may flag one of these archives as malicious on download — `evidence/companion-app/claim-screenshots/12_sataana-virus-claim-reads-repo.png` captures exactly that happening to `GRIP-EMS-v2.3.5.zip`. Expect it, and read it correctly:

- **These archives are byte-identical to the author's own CurseForge releases.** Every hash in this document was taken from the package as CurseForge served it, and `sha256sum -c SHA256SUMS.txt` proves the bytes here match. Nothing was added, repacked, or modified. Whatever a scanner objects to, it objects to in the file **as its author distributes it** — the same bytes any user of the addon already has.
- **A heuristic flag on a WoW addon zip is unremarkable.** Obfuscated or packed Lua, bundled binaries and unusual archive structure all trigger generic heuristics. This package draws **no** conclusion from it: it is **not** alleged that GRIP-EMS contains malware, and nothing here should be read that way.
- **The hash is the authority, not the download.** If a browser blocks the download, verify from the copies in this repository instead. Any file that hashes to the value listed here is the correct evidence, whatever a scanner says about it.

Recorded because it affects the verification route this document recommends, and because it is better stated plainly than discovered mid-review.

## Scope note

These are the author's own published release packages, retained unmodified for evidentiary comparison and cited for the purpose of criticism and analysis. They are not offered as a download of the addon, and no derivative or modified build is distributed here.


### v2.4.8 — GSE.Tools encrypted exports refused, `noExport` honoured (verified 2026-08-26)

Reported by the GSE author 2026-08-26 and verified against the shipped archive the same day.
Credited here on the same terms as the do-not-share gate (v2.3.17) and the fork/rename fix
(v2.4.7).

- **`noExport` honoured.** `Import/LegacyImport.lua:628` — `LI.ResolveNoRedistribute` reads
  `sequence.MetaData.noExport` and returns true when set.
- **`!GSE3!+` refused before decode.** `Data/Defaults.lua:946` defines the encrypted prefix as
  *"protected/subscriber-only; not importable"*; `Import/Serialization.lua:93` refuses it with a
  clear user-facing message and writes nothing. Enforced at **eight call sites** across
  `ImportPreview.lua`, `LegacyImport.lua` and `LegacyMigrate.lua`.

**This is a real protection and it works.** Sequences exported through GSE.Tools with the
current encryption cannot be imported by GRIP-EMS.

**It does not close the claim.** Plain `!GSE3!` — raw in-game exports and copies from a user's
own `GSE.lua` — still import, and on that path `PlatformID` and `HelpURL` remain at zero
references while `sourceChecksum` and `sourceVersion` are preserved from the same `MetaData`
table. See `RELEASE-DELTA-ANALYSIS-2026-08-26.md` §3b, including why an author cannot be
required to use a third party's platform to have their licence observed.

