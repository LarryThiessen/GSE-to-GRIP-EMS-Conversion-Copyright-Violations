# Handoff prompt for a new session

Copy everything in the fenced block below into a fresh Claude Code session to continue this work.

---

```
I'm continuing work on a local git repo. Start by reading it:

  C:\Users\Larry\Documents\`Larry's Crap\GSE United Discord\GSEU Admin\GSEU Creators\`Admin Creators\ScaryLarryGames\Git\GRIP-IP-Complaint

(Note: two folders literally begin with a backtick — "`Larry's Crap" and "`Admin Creators". In bash, escape the backticks: \`  . Read README.md first, then the four docs.)

WHAT THIS IS
An IP/copyright complaint package. I'm Larry Thiessen ("ScaryLarryGames"), author of SLG-Sequences — World of Warcraft macro sequences published on CurseForge under an "All Rights Reserved" license (SLG-Sequences-LICENSE.txt: no redistribution, no derivatives, no removing attribution). The complaint targets the addon "GRIP – Enhanced Macro Sequencer" (GRIP-EMS, CurseForge project 1489414) for reproducing and enabling redistribution of my licensed sequences and stripping the author-bound PlatformID identifier on import.

FACTS ALREADY ESTABLISHED — do not re-derive or contradict these:
1. GRIP's import (Import/LegacyMigrate.lua) reads a user's installed GSE data (GSE.Library / GSESequences), bulk-copies every sequence, records the source GSE version, and OMITS the GSE PlatformID. GRIP's export (Import/GRIPExport.lua) + P2P share (Engine/Transmission.lua) re-share it with no license/redistribution guard. Verified across ALL 64 GRIP releases (data/grip_version_scan.csv).
2. GRIP's PlatformID was introduced by GSE on 2026-04-25 (GSE issue #1893, GSE.Tools Companion sync); first GRIP release after that is v2.0.0. Cite current GRIP v2.3.5 as the operative version.
3. GRIP's SOURCE CODE is NOT copied from GSE — a line-level diff showed only generic WoW/Ace3 boilerplate. DO NOT make a code-copying claim.
4. The community site lazygrip.net was checked for redistributed copies of my sequences — 10 sequences across 7 classes, all other authors' GRIP-"native" builds, ZERO matches. DO NOT include a "they redistributed my sequences" claim; it's disproven.
5. Legal framing: lead with copyright infringement (17 U.S.C. §106) + license breach (clauses 2(a),(b),(d),3) + CurseForge IP policy. The DMCA §1202 / CMI theory (PlatformID removal) is SUPPORTING and legally weak (see grip-1202-cmi-analysis.md) — flag that it needs an IP lawyer; do NOT claim §1201 anti-circumvention.

HONESTY RULES: never overclaim. If something isn't supported by the code, say so. This package's credibility depends on conceding what isn't claimed (§8 of the complaint).

WORKING DATA / TOOLS (outside the repo, may need re-fetching if cleaned):
- GRIP addon zips + the GSE Companion disclosure clone: C:\gsedisc\  (GRIP-EMS-v*.zip also in the repo's evidence/)
- My decoded sequence fingerprints: C:\slg\slg_fingerprints.json ; decoder: C:\slg\match_ems.py
- Decode recipe for GSE3/GRIP1/EMS1 strings: base64-decode after the "!PREFIX!", then raw DEFLATE (python zlib.decompress(data,-15)), then CBOR (python cbor2.loads). Spell steps live in versions[].steps as "{spell:ID}" (GRIP) or "/cast ... ID" (GSE).

STILL TO DO before filing (curseforge-complaint-final.md): fill §1 mailing address/phone, §3 my CurseForge sequence-project URLs, §7 date.

WHAT I WANT YOU TO ADD: <describe your change here, e.g. "draft a cover email", "add a v2.3.5 code appendix", "prepare a Blizzard UI-policy complaint variant">.

When done, commit to the repo (git add -A && commit) with a clear message. Do not push anywhere unless I ask.
```
