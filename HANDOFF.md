# Handoff prompt for a new session

Copy everything in the fenced block below into a fresh Claude Code session to continue this work.

---

```
I'm continuing work on a local git repo. Start by reading it:

  C:\Git\GRIP-IP-Complaint

(Also published at https://github.com/LarryThiessen/GSE-to-GRIP-EMS-Conversion-Copyright-Violations
Read README.md first, then the exhibits it lists.)

WHAT THIS IS
An IP/copyright complaint package. I'm Larry Thiessen ("ScaryLarryGames"), author of SLG-Sequences — World of Warcraft macro sequences published on CurseForge under an "All Rights Reserved" license (SLG-Sequences-LICENSE.txt: no redistribution, no derivatives, no removing attribution). The complaint targets the addon "GRIP – Enhanced Macro Sequencer" (GRIP-EMS, CurseForge project 1489414) for reproducing and enabling redistribution of my licensed sequences and stripping the author-bound PlatformID identifier on import.

FACTS ALREADY ESTABLISHED — do not re-derive or contradict these:
1. GRIP's import (Import/LegacyMigrate.lua) reads a user's installed GSE data (GSE.Library / GSESequences), bulk-copies every sequence, records the source GSE version, and OMITS the GSE PlatformID. GRIP's export (Import/GRIPExport.lua) + P2P share (Engine/Transmission.lua) re-share it with no license/redistribution guard. Verified across ALL 64 GRIP releases (data/grip_version_scan.csv).
2. GRIP's PlatformID was introduced by GSE on 2026-04-25 (GSE issue #1893, GSE.Tools Companion sync); first GRIP release after that is v2.0.0. Cite current GRIP v2.3.5 as the operative version.
3. GRIP's SOURCE CODE is NOT copied from GSE — a line-level diff showed only generic WoW/Ace3 boilerplate. DO NOT make a code-copying claim.
4. lazygrip.net HOSTING is disproven and out of scope — 10 sequences across 7 classes checked, all other authors' GRIP-"native" builds, ZERO matches. DO NOT claim "they re-host my sequences." DISTINCT and IN scope: what LazyGrip's public Workshop TOOLS do to a submitted work — on demand they reproduce a submitted GSE sequence in full plaintext and strip the GSE.Tools CMI on convert (grip-lazygrip-webtool-exhibit.md, captured live 2026-07-12). Never conflate the two.
5. The developers documented the intent BEFORE they built it — "how to bypass the new GSE security system" → "strip the gse tools stuff from gse" → the ARR licence named by name → "Kind of solved it" ~4 hours later. Full record in evidence/discord/ (THE-STORY.md narrative, captures.md verbatim + permalinks + snowflake-decoded UTC timestamps). This supplies the scienter the case previously lacked.
6. Legal framing (REVISED 2026-07 — supersedes any earlier "§1202 is weak" draft):
   - Direct infringement + license breach is THE FLOOR — 17 U.S.C. §106(1),(3) + clauses 2(a),(b),(d),3. Needs no CMI theory and no scienter.
   - Grokster inducement is likely THE LEAD THEORY — clear expression of infringing object (the Discord) + affirmative steps (the shipped capability). Must plead the predicate user copies; capability + intent alone is not infringement.
   - DMCA §1202 is SUPPORTING but materially STRONGER than first assessed — the earlier draft weighed only PlatformID; HelpURL (§1202(c)(5) link to the owner's listing) and Checksum (a real Ed25519 platform signature) are also shown stripped, and the Discord supplies the double-scienter that draft called fatal. Still needs an IP lawyer's read.
   - CurseForge IP policy applies the platform's own standard, not a court's.
   - Do NOT claim §1201 anti-circumvention.

HONESTY RULES: never overclaim. If something isn't supported by the code, say so. This package's credibility depends on conceding what isn't claimed (§8 of the complaint).

WORKING DATA / TOOLS (outside the repo, may need re-fetching if cleaned):
- GRIP addon zips + the GSE Companion disclosure clone: C:\gsedisc\  (GRIP-EMS-v*.zip also in the repo's evidence/)
- My decoded sequence fingerprints: C:\slg\slg_fingerprints.json ; decoder: C:\slg\match_ems.py
- Decode recipe for GSE3/GRIP1/EMS1 strings: base64-decode after the "!PREFIX!", then raw DEFLATE (python zlib.decompress(data,-15)), then CBOR (python cbor2.loads). Spell steps live in versions[].steps as "{spell:ID}" (GRIP) or "/cast ... ID" (GSE).

STILL TO DO before filing (curseforge-complaint-final.md): fill §1 mailing address/phone, §3 my CurseForge sequence-project URLs, §7 date.

WHAT I WANT YOU TO ADD: <describe your change here, e.g. "draft a cover email", "add a v2.3.5 code appendix", "prepare a Blizzard UI-policy complaint variant">.

When done, commit to the repo (git add -A && commit) with a clear message. Do not push anywhere unless I ask.
```
