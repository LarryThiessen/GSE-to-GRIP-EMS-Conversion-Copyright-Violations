# GSE to GRIP-EMS Copyright Complaint Package

Evidence and filing package re: **GRIP – Enhanced Macro Sequencer** (CurseForge project 1489414) reproducing and enabling redistribution of ScaryLarryGames / SLG-Sequences All-Rights-Reserved macro sequences, and removing the author-bound `PlatformID` identifier on import.

Prepared 2026-07-08. Rights holder: Larry A. Thiessen ("ScaryLarryGames").

## Outcome — 2026-08-20

**CurseForge has actioned this claim. GRIP – Enhanced Macro Sequencer (project 1489414) is no longer hosted on CurseForge.**

> "We have completed our review of the reported content and have taken the necessary actions as per your request."
> — CurseForge copyright team, `copyright@curseforge.com`, 2026-08-20 09:31

Verified independently the same day: the project page returns **404**, the files API for mod 1489414 returns an **empty list** where it returned six releases on 2026-08-07, the v2.3.18 download captured on 2026-08-07 is gone, and the project no longer appears on the author's own project listing — while his other projects (GRIP - CORE, GRIP - Guild Recruitment) still do. Captured pages, the API response and SHA-256 hashes are in `evidence/takedown-2026-08-20/`.

**This is not a verdict, and this repository is not a victory lap.** CurseForge state that the reported party may still file a counter claim, in which case the matter returns to review. **Nothing in this package has been softened, removed or rewritten in light of the outcome.** It stands as it stood — including every dated correction, every withdrawn claim, and every point conceded to the other side. Those concessions are why it held up.

**What this record is for.** It documents what was done, how it was done, and — from the developers' own messages — that it was planned before it was built. A platform applied its own policy to evidence anyone can check for themselves. That is the system working as intended.

**Note on the archives.** The addon releases cited throughout can no longer be downloaded from CurseForge, Wago Addons or WoWInterface — all three now serve only the current release. **SHA-256 hashes for every one remain recorded** in `evidence/SHA256SUMS.txt` and `evidence/PROVENANCE.md`, and **every source file the exhibits cite is published unmodified in `evidence/cited-source/`**, so every citation still resolves. The full installable packages for v1.0.4→v2.4.7 were withdrawn from this repository on 2026-08-26 at the addon developer's request, once this package's own stated rule for hosting them — that a third party can independently re-download and compare — stopped being true; the 2026-08-26 addendum in `PROVENANCE.md` records what was verified before acting. They are retained unmodified offline. A reviewer needing a complete package should ask the rights holder.

---

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
| `evidence/cited-source/` | **Every source file any `FILE:LINE` citation in this package resolves into**, extracted unmodified from the official release archives at their original relative paths — 117 files across v1.0.4→v2.4.7, plus a `README.md` explaining coverage, the line-number drift between releases, and how to confirm the extracts are byte-identical to the originals. **Every citation in every exhibit resolves against these directly, no archive needed.** |
| `evidence/GRIP-EMS-v2.4.8.zip` | The current shipped GRIP build, still published on CurseForge, Wago Addons and WoWInterface — so anyone can re-download it, hash it, and compare against `SHA256SUMS.txt`. *The full packages for v1.0.4→v2.4.7 were withdrawn on 2026-08-26; their hashes remain recorded and `cited-source/` carries the cited files. See the addendum in `PROVENANCE.md` for why.* |
| `evidence/GSE-3.3.22.zip` | **GSE**, not GRIP — Timothy Luke's addon, retained unmodified so the GSE-side FILE:LINE citations in the comparison exhibits can be checked from this repo instead of requiring a separate download. |
| `evidence/PROVENANCE.md` | Where every archive came from, when it was captured, its CurseForge file ID and hash, and how a third party verifies it — including the **2026-08-26 addendum** recording the withdrawal of eight full packages, what was independently verified before acting, and what a reviewer needing a complete package should do. Also: how a third party re-downloads and confirms byte-identity. |
| `evidence/OPERATOR-IDENTITY-RESOLVED.md` | **The basis on which operator identities are treated as established** rather than provisional — Sataana / `sirsataana` / `JesperLive` as one person (his own cross-linked accounts + shared avatar + authorship of the disclosure on three platforms), and the LazyGrip Workshop tool authors by in-panel credit and their own words. Records what remains open: the domain registrant is privacy-redacted, and legal-identity verification for a filing goes through the platform or registrar. |
| `evidence/LAZYGRIP-OPERATOR-AND-CONVERTER-PROVENANCE.md` | **Who runs LazyGrip.net, where it runs, and what its own version control says.** The site is built from a public repo (`lazygrip/lazygrip-gg`), so its history is readable: the converter did not carry `PlatformID` / `HelpURL` / `Checksum` / `GSEVersion` until commit `8d541bc` on **2026-07-30 15:53 UTC** — dating the change between the 7/12 and 8/1 tests to the second. Also records two written admissions by the GRIP-EMS developer: that the site's "no affiliation with the GRIP-EMS developer" disclaimer **"is not accurate"**, and that the site's site-wide **CC BY-NC-SA 4.0 claim over user-submitted sequences** was withdrawn because "a submitter cannot grant a Creative Commons licence over a sequence someone else wrote and reserved rights in." Domain, hosting, forum infrastructure, and the full 2026-04-30 → 2026-08-01 timeline. |
| `evidence/lazygrip-site/` | Artefacts for the above: live pages captured 2026-08-01, Internet Archive snapshots of 2026-07-09 (the CC BY-NC-SA footer and the copyright-free ToS), and the converter source as deployed — each with a SHA-256 in `SHA256SUMS.txt`, plus the public URLs to re-check them independently. |
| `evidence/RIGHTS-HOLDER-STATEMENT-2026-08-01.md` | **What the removal of `PlatformID` actually costs the author, stated by the author.** 100% of his sequences are flagged Private on GSE.Tools; a Private sequence may sit in a Public Collection (others may **import** it) and another user may **store** it, but **Export and Install are withheld** from them unless he **approves a fork request** — and he has never approved one for any GRIP-EMS-related party, nor has one ever been asked. So the identifier's removal is not lost attribution: it takes the work out of the system withholding those controls and deletes the step where permission would have been sought. Marked throughout as **testimony, not artifact**, with the platform-behaviour points flagged as awaiting GSE.Tools documentation (requested from Timothy Luke, 2026-08-01) or an operator statement. |
| `evidence/POST-COMPLAINT-CHANGES-2026-08-07.md` | **What changed after the complaint went in, both sides recorded.** GRIP v2.3.17 (2026-08-01) added a do-not-share refusal enforced at nine sites, and it **works** on the in-game migrate path — recorded in full, not as cosmetic. But the operators' own LazyGrip converter carries **zero** references to the field it depends on, across all six modules, while carrying four other GSE fields added on 2026-07-30. So the addon refuses to redistribute a stamped sequence and their website removes the stamp. `PlatformID` and `HelpURL` remain at zero references in the current release, the migrate path is unchanged, and there is **no licence check anywhere** in GRIP's import or export code. Includes the sharpened remedy and the corrections this exhibit forced. |
| `evidence/companion-app/OPERATOR-STATEMENT-2026-08-07.md` | **The GSE.Tools operator confirms the platform stamps every non-owner copy** — *"everyone who is not the original authro gets a dont export stamp on it"* (Timothy Luke, 2026-08-07, message ID and decoded UTC recorded, screenshot hashed). This is what makes GRIP's new gate real on the migrate path, and what makes the converter's omission of the field significant. DM-sourced; flagged as testimony, not artifact. |
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
