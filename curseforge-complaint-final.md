# CurseForge IP / Copyright Complaint — GRIP-EMS

**Submit to:** CurseForge / Overwolf copyright & IP team (support.curseforge.com → "Report copyright / IP infringement," or their designated DMCA/IP agent). Paste this into the form or attach it; attach the technical exhibit and the license.

---

## 1. Complainant (rights holder)

- **Name:** Larry A. Thiessen
- **Doing business as:** ScaryLarryGames ("SLG")
- **Contact:** on file with CurseForge/Overwolf — email, mailing address and phone were supplied directly on filing and are withheld from this public copy.
- **Role:** Author and copyright owner of the works identified in §3.

## 2. The project complained about

- **Project:** GRIP – Enhanced Macro Sequencer ("GRIP-EMS")
- **Author (CurseForge):** Sataana (MrSataana / JesperLive)
- **CurseForge project ID:** 1489414
- **URL:** https://www.curseforge.com/wow/addons/grip-enhanced-macro-sequencer
- **Scope:** all releases; the functionality complained of is present in every release from v1.0.4 (2026-03-21) through the current **v2.3.16** (verified 2026-07-29, SHA-256 `5c1499cf695b1c82…`; zero `PlatformID` across its 198 Lua files) (2026-07-03).

## 3. My copyrighted works and their license

- **Works:** original World of Warcraft macro **sequences** I authored under the "SLG-Sequences" name — the macro step logic, step ordering, variables, and associated metadata are original creative expression fixed in a tangible medium.
- **Publication:** on my CurseForge sequence projects (URLs): __________ .

- **Every one of my sequences is flagged Private on GSE.Tools, and always has been — 100%, without exception.** This applies to every supporter and every person who downloads them. A Private sequence may be placed in a Public Collection, which allows others to **import** it, and another user may **store** it in their own GSE.Tools library. What they cannot do is **export or install it** — those controls are not available to them — unless they submit a **fork request that I approve**. I have never approved such a request for any GRIP-EMS-related party.

  The **`PlatformID`** is the token by which GSE.Tools identifies a sequence as mine and enforces that restriction. Its removal does not merely strip attribution: it removes the work from the system that was withholding the export and install controls, and eliminates the fork-approval step through which my permission would otherwise have been sought. *(This paragraph replaces an earlier statement that "roughly 80% of my sequences are distributed privately." That figure described distribution reach and was misleading as to permissions: the Private flag is not partial, it is universal. Corrected 2026-08-01.)*
- **License:** each of my sequence projects is published with its Project License set to **"All Rights Reserved,"** whose full text is the SLG-Sequences License (attached; also at `github.com/LarryThiessen/SLG-Sequences`). It **prohibits** redistribution, re-hosting, distribution of derivative versions, and removal/alteration of author or attribution notices, and reserves all rights (clauses 2(a), 2(b), 2(d), 3, 4). The no-redistribution terms are therefore publicly posted on every project page.

- **What the license does permit — stated so the claim is not overstated.** Clause 1 grants each user a personal, non-exclusive, non-transferable, revocable license to download and use the Work for their **own personal, non-commercial use in World of Warcraft, including modifying it for their own personal use**. I do not claim that a user converting a sequence for their own private use breaches that grant. **My claim concerns clauses 2(a) and 2(b)** — redistribution, re-hosting or publishing the Work on any website, platform or service, and distributing or sharing modified or **derivative versions** of it. A sequence of mine re-encoded into another addon's native format is a derivative version; distributing that derivative is what the license forbids, whether or not my name survives the conversion.

- **No permission has been granted, and none has been sought.** *(Recorded 2026-08-01. This statement is added as of that date; earlier versions of this complaint carried only the good-faith belief statement at §7 and did not state the point affirmatively.)* I have never granted permission — written or otherwise — to the GRIP-EMS project, to its developer, to LazyGrip.net or its operators, or to any other person or service, to reproduce, convert, re-encode, redistribute, re-host, publish or prepare derivative versions of my SLG-Sequences works. **No such permission has ever been requested of me.** The prior written permission required by clause 2 has therefore never existed at any point.

## 4. The infringing conduct

GRIP-EMS contains functionality that, without my authorization and contrary to the All-Rights-Reserved license above, reproduces my copyrighted sequences and enables their redistribution. Every step is verifiable in GRIP's shipped, plain-text Lua on CurseForge (file/line citations in the attached exhibit):

1. **Reproduction.** GRIP's migration/import (`Import/LegacyMigrate.lua`) reads the user's installed GSE data — the in-memory sequence library (`GSE.Library`, force-decompressing every class) and the `GSE.lua` SavedVariables (`GSESequences`) — and **bulk-copies every sequence present**, including my sequences that a user has, into GRIP's own storage.

2. **Knowledge of origin.** GRIP records, per sequence, the **source GSE version** it imported from (`Import/LegacyImport.lua`, `importMeta.sourceVersion = ...MetaData.GSEVersion`), demonstrating awareness that the content is third-party GSE-authored.

3. **Removal of the author identifier.** On import, GRIP copies a fixed set of fields (author label, description, spec, timestamp, icon, class) and **omits the `PlatformID`** — the GSE.Tools identity that binds each of my sequences to my author account. `PlatformID` appears nowhere in GRIP's code. My license expressly forbids removal or alteration of author/attribution notices (clause 2(d)).

4. **Redistribution.** GRIP re-encodes the copied sequence into its own shareable formats (`Import/GRIPExport.lua`; `!GRIP1!`/`!EMS1!` strings) and provides **player-to-player distribution** (`Engine/Transmission.lua`, AceComm sharing). There is no license check, author-permission check, or redistribution guard in that path.

**Net effect:** my All-Rights-Reserved sequences — including private, supporter-only sequences never licensed for distribution — are reproduced into GRIP, stripped of the identifier binding them to my account, and made freely redistributable, without my permission and in violation of my posted license.

## 5. Why this infringes my rights and violates CurseForge policy

- **Copyright infringement:** unauthorized **reproduction** (17 U.S.C. § 106(1)) and **distribution** (§ 106(3)) of my original copyrighted sequences, and preparation/distribution of **derivative** re-encoded versions (§ 106(2)).
- **License violation:** my works are posted **All Rights Reserved**; GRIP's reproduction and redistribution breach SLG-Sequences License clauses **2(a)** (no redistribution/re-hosting), **2(b)** (no distribution of derivative versions), **2(d)** (no removal/alteration of author or attribution notices), and **3** (subscriber/paid content may not be shared).
- **CurseForge IP policy:** CurseForge's project-moderation policy prohibits projects that infringe the intellectual property rights of others. GRIP provides, as a core feature, the unauthorized reproduction and redistribution of other creators' All-Rights-Reserved content.

*(A supporting statutory theory — removal of copyright-management information under 17 U.S.C. § 1202, based on the `PlatformID` omission in §4(3) — is set out in a separate legal memo and is not necessary to this complaint.)*

## 6. Requested remedy

Under CurseForge's IP/moderation policy, I request that CurseForge require GRIP-EMS to, at minimum:

1. **Cease reproducing and enabling redistribution of third-party All-Rights-Reserved sequences** without the author's consent — specifically, gate or remove the GSE-import and re-export/share functionality so that sequences imported from GSE cannot be re-exported or shared unless the original author has permitted redistribution, and cease removing the author-bound `PlatformID` identifier from imported content; or
2. Failing that, **removal of the infringing functionality (or the project)** under CurseForge's IP-infringement policy.

## 7. Required statements

- I have a good-faith belief that the use of my copyrighted works in the manner described is not authorized by me, my agent, or the law.
- **Affirmatively, and not merely as a belief:** I have never granted permission to the GRIP-EMS project, its developer, LazyGrip.net or its operators, or any other person or service, to reproduce, convert, re-encode, redistribute, re-host, publish or prepare derivative versions of my works. No such permission has ever been requested of me. My works are authored for and published to the GSE ecosystem; I have not licensed them for use in, conversion to, or distribution through any other addon or platform.
- The information in this notification is accurate, and **under penalty of perjury**, I am the owner, or authorized to act on behalf of the owner, of the copyright(s) that are allegedly infringed.
- I request that CurseForge take action in accordance with its policies and applicable law.

**Signature:** Larry A. Thiessen ("ScaryLarryGames")
**Date:** __________

## 8. Scope (what is and isn't claimed)

- This complaint concerns GRIP's **handling of sequence content authored by third parties** — its unauthorized reproduction and redistribution of my licensed sequences, and its removal of the author-bound `PlatformID` from that content. It is **not** a claim that GRIP's own program source code was copied from another addon.
- A user converting **their own installed copy** of a sequence for **personal use** is not the target. The conduct complained of is (a) reproducing **other creators'** licensed content and (b) enabling its **redistribution** with the author identifier removed.

## 9. Attachments

- `grip-cmi-evidence-exhibit.md` — code-cited technical exhibit (import→export path with file/line citations; per-version confirmation across all releases; SLG license).
- SLG-Sequences License (full text; also in the exhibit, Appendix B).
- (Optional) `grip-1202-cmi-analysis.md` — supporting §1202 legal memo.
