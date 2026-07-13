# GRIP-EMS — IP / Copyright Complaint Package

Evidence and filing package re: **GRIP – Enhanced Macro Sequencer** (CurseForge project 1489414) reproducing and enabling redistribution of ScaryLarryGames / SLG-Sequences All-Rights-Reserved macro sequences, and removing the author-bound `PlatformID` identifier on import.

Prepared 2026-07-08. Rights holder: Larry A. Thiessen ("ScaryLarryGames").

## ★ Start here — the chain of events

**Open [`START HERE.html`](<START HERE.html>) in any web browser** (just double-click it). It's a self-contained page (no internet needed) that walks anyone — no technical background required — through the entire story in order, with every Discord message shown as an embedded screenshot and linked to its live permalink, plus a plain-English "what GRIP's code does" and an honest "proven vs. not proven" section. To make a shareable file, open it and **Print → Save as PDF** (it's print-formatted). Everything else in this repo is the underlying evidence and the formal complaint that this page summarizes.

## Contents

| File | What it is |
|---|---|
| `curseforge-complaint-final.md` | **The complaint to file** with CurseForge/Overwolf. Code + license only. Fill address, project URLs, date before submitting. |
| `grip-cmi-evidence-exhibit.md` | Code-cited technical exhibit — the import→export path with file/line citations, confirmed across all 64 GRIP releases, plus the SLG license (Appendix B). Attach to the complaint. |
| `grip-1202-cmi-analysis.md` | Supporting legal memo on the DMCA §1202 / CMI theory. **Two-sided; not legal advice** — take to an IP lawyer. |
| `grip-vs-gse-forensic-comparison.md` | **Primary code exhibit.** Full five-subsystem source-to-source diff of both codebases. Three parts: (1) GRIP replicates GSE's non-platform-mandated signature design — the Priority `N·(N+1)/2` expansion is output-identical; (2) GRIP engineered a workaround for GSE's documented anti-scraping lock; (3) GRIP strips the owner-identifying `PlatformID`/`HelpURL`/`Checksum`. Concludes: functional/design clone, **not** source-copied; states what to plead and what not to. |
| `grip-vs-gse-functional-identity.md` | Companion exhibit: GRIP is functionally/architecturally/format-identical to GSE (same container, data model, secure engine, advance-every-press behavior, conditional syntax), and its marketed "holds on failed cast" differentiator is **not implemented** in its engine code. Behavioral identity only — **not** a code-copying claim. |
| `grip-lazygrip-webtool-exhibit.md` | Exhibit on LazyGrip.net's public Workshop web tools: on-demand plaintext reproduction of a submitted sequence, and server-side removal of GSE.Tools CMI (`PlatformID` + `HelpURL` gse.tools link + `Checksum`) on convert. Live before/after captured 2026-07-12. |
| `evidence/lazygrip-webtool/` | Reproducible data for the above: rights holder's original `!GSE3!` + faithful decode, and a third-party GSE→GRIP before/after showing the strip. Screenshots to be added under `screenshots/`. |
| `evidence/discord/THE-STORY.md` | **★ Start here for the Discord evidence.** Plain-English narrative of House of Macros' own Discord messages — Sataana's "how to bypass the new GSE security system" plan, the AI/AGPL/GitHub reverse-engineering thread, CzarTheMad naming "Slg"'s Patreon by handle and paid-member count, and the ban corroboration. Chronological, quote-by-quote. |
| `evidence/discord/captures.md` | Full verbatim capture log backing the story — every quote, decoded UTC timestamp (from Discord message-ID snowflakes), and permalink. Also shared into the `GSE-vs-GRIP-CopyRight-Violations` repo (Timothy Luke's case) since it's relevant to both. |
| `SLG-Sequences-LICENSE.txt` | The All-Rights-Reserved license the works are published under. |
| `data/grip_version_scan.csv` | Per-version scan of all 64 GRIP releases (v1.0.4→v2.3.5): each reads GSE data, carries zero `PlatformID`, drops the author ID. |
| `data/version_scan_raw.csv` | Raw scan output (file IDs, reference). |
| `evidence/GRIP-EMS-v1.0.4.zip` `v1.9.1.zip` `v2.3.5.zip` | The actual shipped GRIP addon builds cited in the exhibit (earliest, mid, current). |
| `evidence/SHA256SUMS.txt` | SHA-256 hashes of the three zips (chain of evidence). |

## The core claim (what's solid)

1. GRIP's `Import/LegacyMigrate.lua` reads the user's installed GSE data (`GSE.Library` / `GSESequences`) and bulk-copies every sequence.
2. It records the source GSE version (knowledge of origin).
3. It omits the author-bound `PlatformID` — present in no GRIP release.
4. `Import/GRIPExport.lua` + `Engine/Transmission.lua` re-encode and P2P-share the result with no license/redistribution guard.

Grounds: copyright infringement (17 U.S.C. §106) + breach of the SLG-Sequences license (clauses 2(a),(b),(d),3) + CurseForge IP policy. `PlatformID` removal is a supporting §1202/CMI theory (get a lawyer's read first).

## Before filing

- Fill the three blanks in `curseforge-complaint-final.md` (§1 address/phone, §3 CurseForge project URLs, §7 date).
- Attach `grip-cmi-evidence-exhibit.md` and `SLG-Sequences-LICENSE.txt`.
- This is an IP-policy/functionality complaint (GRIP's *download* does not itself contain the sequences), so CurseForge has discretion. It is **not** a source-code-copying claim.

## Explicitly out of scope

An investigation into whether the community site **lazygrip.net** *hosts / redistributes copies* of these sequences returned **no matches** — the sequences checked were other authors' own GRIP-native builds. That **hosting** angle is deliberately excluded; do not include it.

**Distinct and in scope (see `grip-lazygrip-webtool-exhibit.md`):** the *function* of LazyGrip's public Workshop tools — on demand, they reproduce a submitted GSE sequence in full plaintext and strip the GSE.Tools CMI (`PlatformID` + `HelpURL` gse.tools link + `Checksum`) when converting to GRIP. This is about what the tools do to a submitted work, not about hosting a library — the two must not be conflated.
