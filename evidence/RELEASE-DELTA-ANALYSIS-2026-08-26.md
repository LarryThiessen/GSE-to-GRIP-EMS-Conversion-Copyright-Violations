# Release-delta analysis — v2.3.18 → v2.4.8

**Compiled:** 2026-08-26. Every figure below is reproducible from the archives and extracts in
this repository; the method is stated at the end.

**What this exhibit is for.** The claim in this package is that GRIP-EMS reproduces
All-Rights-Reserved sequences and discards `PlatformID`, the identifier binding each to its
author's GSE.Tools account. A natural answer is that the project is small, or busy, or that the
omission is an oversight nobody got to. This exhibit tests that answer against the developer's own
release history across the period the claim was live.

---

## 1. Scale of change, release to release

| Transition | Lines changed | Files changed | New files |
|---|---|---|---|
| v2.3.18 → v2.4.6 | **8,193** | 152 | 13 |
| v2.4.6 → v2.4.7 | 78 | 2 | 0 |
| v2.4.7 → v2.4.8 | **2,995** | 157 | 3 |

v2.4.7 is a maintenance release: 69 of its 78 changed lines are in the bundled third-party library
`Libs/LibSharedMedia-3.0`, and the remaining 9 are in `UI/WhatsNew.lua`, the changelog popup.

The other two are substantial. Across the three transitions the developer changed **11,266 lines
across 311 file-revisions and added 16 new files** — including a keybind-conflict subsystem, a
do-not-share refusal, an author-confirmation flow, and a structural CI test that parses a field
list out of `Data/Defaults.lua` and asserts every member is carried at four separate rebuild sites.
This is not a dormant project or an unmaintained one.

## 2. What happened in the five files the claim concerns

Header-only edits — `Updated:`, `Patch:`, `(c)`, `Not licensed for AI` — are excluded. These are
**non-header** changed lines.

| File | v2.3.18→v2.4.6 | v2.4.6→v2.4.7 | v2.4.7→v2.4.8 |
|---|---|---|---|
| `Import/LegacyMigrate.lua` | 0 | 0 | 2 |
| `Import/LegacyImport.lua` | 143 | 0 | 25 |
| `Import/GRIPExport.lua` | **0** | 0 | **551** |
| `Engine/Transmission.lua` | **0** | 0 | **341** |
| `Engine/Identity.lua` | **0** | 0 | 37 |

**Read the two big releases differently, because they are different.**

**v2.4.6** is the one where the omission looks like inattention: 8,193 lines changed across the
addon, and `GRIPExport.lua`, `Transmission.lua` and `Identity.lua` received **no functional edit at
all** — only a date and a patch string. `LegacyMigrate.lua`, the function that copies the library
out of GSE, was opened, re-dated to 2026-08-17, and otherwise left exactly as it was.

**v2.4.8 is the opposite, and it is the stronger fact.** He rewrote **551 non-header lines of
`GRIPExport.lua`** — roughly 30% of a 1,821-line module — and **341 of `Transmission.lua`**. Those
are precisely the files that assemble an export payload and put it on the wire. He was working
inside the export path extensively and deliberately, adding `GE.IsLocallyAuthored`,
`GE.NeedsAuthorConfirm`, `FirstForeignAncestorAuthor` and a confirmation dialog, wired at 18 call
sites in `GRIPExport.lua` and 10 in `Transmission.lua`.

**`PlatformID` and `HelpURL` still appear zero times in v2.4.8.** Not in those files, not anywhere
in the addon.

> **Correction, recorded rather than quietly fixed.** An earlier working note in this project
> stated that in v2.4.8 the key files were "touched only to bump a date and a patch string." That
> is accurate for v2.4.6 and v2.4.7 and **wrong for v2.4.8**, where two of them were substantially
> rewritten. The corrected finding is narrower and better evidenced, and it is the one that should
> be relied on.

## 3. Why "it would have been difficult" does not survive this

Four things are true at the same time, each verifiable:

1. **The identifier arrives in the payload already.** Since commit `8d541bc` (2026-07-30), the
   operators' own LazyGrip.net converter deliberately writes `platformId`, `helpUrl`, `checksum`
   and `gseVersion` into the GRIP payload it produces. See
   `LAZYGRIP-OPERATOR-AND-CONVERTER-PROVENANCE.md` §5. The addon references `platformId` **zero**
   times: the data is handed to it and nothing reads it.
2. **The enforcement point exists and he built it.** `GE.IsNoRedistribute` refuses an export
   before any payload is constructed — their own comment: *"no payload table, no encoded string,
   nothing for a caller to salvage"* — and is called at 13 sites as of v2.4.8. A `PlatformID`
   check would sit in the same place, in the same function, in the file he rewrote 551 lines of.
3. **He demonstrably ships this class of fix quickly.** The do-not-share refusal went from absent
   in v2.3.16 to enforced at nine sites in v2.3.17 — published **2026-08-01**, the day the
   copyright claim was filed. In v2.4.8 he extended it, fixed a carry bug across four rebuild
   sites, and added a structural test to keep it fixed.
4. **He reads and acts on third-party ownership signals when he chooses to.** The v2.4.8
   author-confirmation reads `originalAuthorIdentity`, `forkedFrom` and `forkedFromChain` to decide
   whether a sequence is someone else's work. That is the same category of check as reading
   `PlatformID`, implemented on the same data structure, in the same release.

**What is claimed here:** the capability, the data, the enforcement point and the demonstrated
willingness all exist, and the identifier is still discarded. **What is not claimed:** any motive.
No inference about intent is drawn or needed. The counts are the record.

## 4. Method

```bash
# per-transition totals
diff -rq <old>/GRIP-EMS <new>/GRIP-EMS      # file-level
diff <old>/<file> <new>/<file> | grep -c '^[<>]'   # line-level, per shared .lua

# non-header counts exclude these comment lines only:
#   -- Updated:   -- Patch:   -- Created:   -- Version:   -- (c)   -- Not licensed
```

Sources: `evidence/GRIP-EMS-v2.4.8.zip` (still published on CurseForge, Wago Addons and
WoWInterface — re-downloadable and hash-comparable) and `evidence/cited-source/` for the withdrawn
releases. SHA-256 for every archive is in `SHA256SUMS.txt` and `PROVENANCE.md`. `Libs/` and
`Media/` are third-party or non-code and are excluded from the per-file table but included in the
whole-addon totals in §1.
