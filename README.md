# GSE to GRIP-EMS Copyright Complaint Package

Evidence and filing package re: **GRIP – Enhanced Macro Sequencer** (CurseForge project 1489414) reproducing and enabling redistribution of ScaryLarryGames / SLG-Sequences All-Rights-Reserved macro sequences, and removing the author-bound `PlatformID` identifier on import.

Prepared 2026-07-08. Rights holder: Larry A. Thiessen ("ScaryLarryGames").

## ★ Start here — the chain of events

### → **[Read it in your browser, right now](https://larrythiessen.github.io/GSE-to-GRIP-EMS-Conversion-Copyright-Violations/)** ←

No download, no setup — that link opens the whole walkthrough as a web page.

Prefer it offline? Click the green **Code** button at the top of this repo → **Download ZIP**, unzip, and double-click **`START HERE.html`**. The whole repo comes with it, so every screenshot and exhibit works with no internet. (Clicking `START HERE.html` *inside GitHub* shows a blank page saying it's too big to display — the file is 2.28 MB and GitHub won't render HTML anyway. Nothing is wrong with it; use the browser link above.)

It's a self-contained page (no internet needed) that walks anyone — no technical background required — through the entire story in order, with every Discord message shown as an embedded screenshot and linked to its live permalink, plus a plain-English "what GRIP's code does" and an honest "proven vs. not proven" section. To make a shareable file, open it and **Print → Save as PDF** (it's print-formatted). Everything else in this repo is the underlying evidence and the formal complaint that this page summarizes.

## Contents

| File | What it is |
|---|---|
| `curseforge-complaint-final.md` | **The complaint to file** with CurseForge/Overwolf. Code + license only. Fill address, project URLs, date before submitting. |
| `grip-cmi-evidence-exhibit.md` | Code-cited technical exhibit — the import→export path with file/line citations, confirmed across all 64 GRIP releases, plus the SLG license (Appendix B). Attach to the complaint. |
| `grip-1202-cmi-analysis.md` | Legal memo — **DMCA §1202 (CMI removal) + *Grokster* inducement**. **Two-sided; not legal advice** — take to an IP lawyer. *Revised 2026-07: supersedes an earlier draft that rated §1202 "weak." That draft considered only `PlatformID`; the claim is materially stronger now that `HelpURL` (a link to the owner's listing — §1202(c)(5)) and `Checksum` (a real Ed25519 platform signature) are also shown stripped, and the Discord record supplies the double-scienter the draft called the fatal weakness.* |
| `grip-vs-gse-forensic-comparison.md` | **Primary code exhibit.** Full five-subsystem source-to-source diff of both codebases. Three parts: (1) GRIP replicates GSE's non-platform-mandated signature design — the Priority `N·(N+1)/2` expansion is output-identical; (2) GRIP engineered a workaround for GSE's documented anti-scraping lock; (3) GRIP strips the owner-identifying `PlatformID`/`HelpURL`/`Checksum`. Concludes: functional/design clone, **not** source-copied; states what to plead and what not to. |
| `grip-vs-gse-functional-identity.md` | Companion exhibit: GRIP is functionally/architecturally/format-identical to GSE (same container, data model, secure engine, advance-every-press behavior, conditional syntax), and its marketed "holds on failed cast" differentiator is **not implemented** in its engine code. Behavioral identity only — **not** a code-copying claim. |
| `grip-lazygrip-webtool-exhibit.md` | Exhibit on LazyGrip.net's public Workshop web tools: on-demand plaintext reproduction of a submitted sequence, and server-side removal of GSE.Tools CMI (`PlatformID` + `HelpURL` gse.tools link + `Checksum`) on convert. Live before/after captured 2026-07-12. |
| `evidence/lazygrip-webtool/` | Reproducible data for the above: rights holder's original `!GSE3!` + faithful decode, and a third-party GSE→GRIP before/after showing the strip. Screenshots to be added under `screenshots/`. |
| `evidence/discord/THE-STORY.md` | **★ Start here for the Discord evidence.** Plain-English narrative of House of Macros' own Discord messages — Sataana's "how to bypass the new GSE security system" plan, the AI/AGPL/GitHub reverse-engineering thread, CzarTheMad naming "Slg"'s Patreon by handle and paid-member count, and the ban corroboration. Chronological, quote-by-quote. |
| `evidence/discord/captures.md` | Full verbatim capture log backing the story — every quote, decoded UTC timestamp (from Discord message-ID snowflakes), and permalink. Also shared into the `GSE-Addon-vs-GRIP-EMS-Addon-Copyright-Violations` repo (Timothy Luke's case) since it's relevant to both. |
| `SLG-Sequences-LICENSE.txt` | The All-Rights-Reserved license the works are published under. |
| `data/grip_version_scan.csv` | Per-version scan of all 64 GRIP releases (v1.0.4→v2.3.5): each reads GSE data, carries zero `PlatformID`, drops the author ID. |
| `data/version_scan_raw.csv` | Raw scan output (file IDs, reference). |
| `evidence/GRIP-EMS-v1.0.4.zip` `v1.9.1.zip` `v2.3.5.zip` `v2.3.16.zip` | The actual shipped GRIP addon builds cited in the exhibits — earliest, mid, the version the exhibits cite as operative, and the current release (CurseForge file IDs 7791035 / 7918661 / 8364957 / 8537834). |
| `evidence/GSE-3.3.22.zip` | **GSE**, not GRIP — Timothy Luke's addon, retained unmodified so the GSE-side FILE:LINE citations in the comparison exhibits can be checked from this repo instead of requiring a separate download. |
| `evidence/PROVENANCE.md` | Where every archive above came from, when it was captured, its CurseForge file ID and hash, and how a third party re-downloads and confirms byte-identity. |
| `evidence/OPERATOR-IDENTITY-RESOLVED.md` | **The basis on which operator identities are treated as established** rather than provisional — Sataana / `sirsataana` / `JesperLive` as one person (his own cross-linked accounts + shared avatar + authorship of the disclosure on three platforms), and the LazyGrip Workshop tool authors by in-panel credit and their own words. Records what remains open: the domain registrant is privacy-redacted, and legal-identity verification for a filing goes through the platform or registrar. |
| `evidence/LAZYGRIP-OPERATOR-AND-CONVERTER-PROVENANCE.md` | **Who runs LazyGrip.net, where it runs, and what its own version control says.** The site is built from a public repo (`lazygrip/lazygrip-gg`), so its history is readable: the converter did not carry `PlatformID` / `HelpURL` / `Checksum` / `GSEVersion` until commit `8d541bc` on **2026-07-30 15:53 UTC** — dating the change between the 7/12 and 8/1 tests to the second. Also records two written admissions by the GRIP-EMS developer: that the site's "no affiliation with the GRIP-EMS developer" disclaimer **"is not accurate"**, and that the site's site-wide **CC BY-NC-SA 4.0 claim over user-submitted sequences** was withdrawn because "a submitter cannot grant a Creative Commons licence over a sequence someone else wrote and reserved rights in." Domain, hosting, forum infrastructure, and the full 2026-04-30 → 2026-08-01 timeline. |
| `evidence/lazygrip-site/` | Artefacts for the above: live pages captured 2026-08-01, Internet Archive snapshots of 2026-07-09 (the CC BY-NC-SA footer and the copyright-free ToS), and the converter source as deployed — each with a SHA-256 in `SHA256SUMS.txt`, plus the public URLs to re-check them independently. |
| `evidence/SHA256SUMS.txt` | SHA-256 hashes of every archive above (chain of evidence). |
| `correspondence/2026-07-cf-claim-thread.md` | The CurseForge thread: claim submitted, their acknowledgement, the follow-up sent, what's awaited, and how to answer the anticipated pushback. Keep updated. |
| `RESPONSE-to-companion-disclosure.html` | **The public answer to the "GSE Companion is malware" claim.** Point by point, checked against the shipped build. |
| `RESPONSE-brief-for-Tim.html` | The same material as a short brief for GSE's author. |
| `evidence/companion-app/COMPANION-FORENSIC-FINDINGS.md` | **The audit behind that response.** Hash-anchored to the exact `app.asar` the discloser examined, so his own evidence tests his own conclusions. Finding: the destructive routine ran only under `restricted && enforce`; the discloser's own captures record `enforce: false` on all three dates he sampled; it is absent from the shipping build. Concedes a real unsigned diagnostic-upload residual rather than clearing everything. |
| `evidence/companion-app/OPERATOR-STATEMENT-2026-07-29.md` | GSE's author — who runs the server — settling the two facts the audit said only the operator could confirm: there was **no server-side enforce capable of being set true**, and all diagnostic uploads are now tied to a user-initiated request. Testimony, not artifact; flagged as such. |
| `evidence/companion-app/COMPANION-APP-FIX.md` | The remediation the audit recommends (per-request ed25519 signing on the diagnostic path). |
| `evidence/companion-app/discloser-own-evidence/` | The discloser's **own** committed files — `hashes.txt` and the three `live_access_policy_*.json` captures. The `enforce: false` finding rests on his evidence, not ours. |
| `evidence/companion-app/claim-screenshots/` | Screenshots behind the claims and rebuttals, incl. `02_tim-reply-canary.png` (GSE's author on the canary, and on not being asked first) and `01_kephas-video-page.png`. |

## The core claim (what's solid)

1. GRIP's `Import/LegacyMigrate.lua` reads the user's installed GSE data (`GSE.Library` / `GSESequences`) and bulk-copies every sequence.
2. It records the source GSE version (knowledge of origin).
3. It omits the author-bound `PlatformID` — present in no GRIP release.
4. `Import/GRIPExport.lua` + `Engine/Transmission.lua` re-encode and P2P-share the result with no license/redistribution guard.

5. **The developers documented the intent before they built it** — *"how to bypass the new GSE security system"* → *"strip the gse tools stuff from gse"* → the ARR licence named by name → *"Kind of solved it"* ~4 hours later (`evidence/discord/`). The shipped code matches the plan, in every release.

Grounds, in order of strength:
- **Direct infringement + license breach (the floor)** — unauthorized reproduction/distribution (17 U.S.C. §106(1),(3)) in breach of the SLG-Sequences license (2(a),(b),(d),3). Needs no CMI theory and no scienter showing.
- ***Grokster* inducement (likely the lead theory)** — a tool distributed with the object of promoting infringing use, shown by clear expression (the Discord) + affirmative steps (the shipped capability). Note: requires pleading the predicate user copies; capability + intent alone is not infringement.
- **DMCA §1202 (supporting)** — removal of `HelpURL` / `Checksum` / `PlatformID`. Much stronger than first assessed, but still get a lawyer's read.
- **CurseForge IP policy** — the platform applies its own standard, not a court's; documented intent + shipped capability suffices there.

## Status — FILED

The CurseForge claim has been **submitted with the evidence** (see `correspondence/`). CurseForge acknowledged receipt and is reviewing; a follow-up was sent to confirm the reported infringing project is logged as **GRIP-EMS (1489414)** and to obtain a case reference — their acknowledgement quoted one of the rights holder's *own* project URLs, so the direction of the claim needed confirming.

The 14 works claimed are all of the rights holder's CurseForge projects: **GSE: Tracker** plus the 13 **GSE:SLG** class sequence sets — each published All Rights Reserved.

Notes for any further filing:
- This is an IP-policy/functionality complaint (GRIP's *download* does not itself contain the sequences), so CurseForge has discretion. It is **not** a source-code-copying claim.
- If CurseForge pushes back with *"GRIP's download doesn't contain your files,"* that is the anticipated response — answer from the code (`grip-cmi-evidence-exhibit.md`) and the intent record (`evidence/discord/`), not by re-arguing the filing.

## Explicitly out of scope

An investigation into whether the community site **lazygrip.net** *hosts / redistributes copies* of these sequences returned **no matches** — the sequences checked were other authors' own GRIP-native builds. That **hosting** angle is deliberately excluded; do not include it.

**Distinct and in scope (see `grip-lazygrip-webtool-exhibit.md`):** the *function* of LazyGrip's public Workshop tools — on demand, they reproduce a submitted GSE sequence in full plaintext and strip the GSE.Tools CMI (`PlatformID` + `HelpURL` gse.tools link + `Checksum`) when converting to GRIP. This is about what the tools do to a submitted work, not about hosting a library — the two must not be conflated.
