# Analytical memo — DMCA §1202 (CMI removal) and Grokster inducement against GRIP-EMS

> **THIS IS NOT LEGAL ADVICE.** Not a lawyer; no attorney–client relationship. This is a structured issue analysis prepared for the rights holder to take **to** qualified counsel. Every citation must be independently verified by an attorney before any reliance. Deliberately two-sided: the defense's best arguments are stated alongside the claimant's.

**REVISION NOTE — supersedes the earlier draft.** The first version of this memo asked only whether `PlatformID` was CMI and rated § 1202 *"colorable but not strong."* **That assessment is obsolete and understated the case**, for two reasons established afterwards:

1. The CMI at issue is **not just `PlatformID`** (an opaque server key). GRIP also strips **`HelpURL`** — a literal URL to the owner's canonical listing — and **`Checksum`** — a real Ed25519 platform signature. Both are materially stronger CMI than an opaque ID.
2. A contemporaneous **Discord record** supplies the double-scienter element the earlier draft called the claim's fatal weakness. It is no longer inferential; the developers put it in writing before they built it.

---

## Questions presented

1. Does the information GRIP removes from imported GSE sequences constitute **copyright management information** under 17 U.S.C. § 1202(c)?
2. Is there a viable **§ 1202(b)** removal/distribution claim?
3. Is there a viable **inducement / contributory infringement** claim under *MGM Studios v. Grokster*, 545 U.S. 913 (2005)?

---

## The law

**§ 1202(c) — definition.** CMI is enumerated information "conveyed in connection with copies … of a work," including: (2) the author's name and identifying information; (3) the copyright owner's name and identifying information; (4) terms and conditions for use; and **(5) "identifying numbers or symbols referring to such information, or links to such information."** Courts hold CMI is **not** limited to "automated copyright protection or management systems," and applies regardless of the form in which it is conveyed (majority view, rejecting the narrow reading of *IQ Group v. Wiredccommerce*, 409 F. Supp. 2d 587 (D.N.J. 2006), and *Textile Secrets Int'l v. Ya-Ya Brand*, 524 F. Supp. 2d 1184 (C.D. Cal. 2007)). CMI has been held to include a file's **metadata**.

**§ 1202(b) — prohibited acts + double scienter.** No person shall, without authority, (1) intentionally remove/alter CMI, or (3) distribute works knowing CMI has been removed — **knowing, or having reason to know, that it "will induce, enable, facilitate, or conceal" an infringement.** *Stevens v. CoreLogic, Inc.*, 899 F.3d 666 (9th Cir. 2018) requires this **double scienter**; "will" means *likely*, not *might*. *CoreLogic* **rejected** the claim for failure of the second prong, but held the knowledge may be proven by a defendant's **"pattern of conduct" or "modus operandi."** *Mango v. BuzzFeed, Inc.*, 970 F.3d 167 (2d Cir. 2020): awareness that distributing without proper CMI will conceal one's own infringing conduct satisfies the second prong.

---

## Issue 1 — Is the removed information CMI?

Three distinct items are stripped. They are **not** of equal strength. Plead them in this order.

### (a) `HelpURL` — the strongest. A link to the owner's listing.
Each GSE sequence carries `MetaData.HelpURL = https://gse.tools/sequences/<PlatformID>` — a human-readable URL resolving to the author's canonical published listing. GRIP carries it nowhere (**zero occurrences** in the shipped tree, all versions).

§ 1202(c)(5) expressly includes *"identifying numbers or symbols referring to such information, **or links to such information**."* A URL pointing to the owner's own listing page is the paradigm case of a "link to such information." This largely answers the "it's just a functional database key" defense that sank the earlier draft: a `gse.tools` URL is not a functional key — it has **no operational role inside GRIP whatsoever**; it is purely an attribution pointer.

### (b) `Checksum` — an Ed25519 signature, not a hash.
`GSE/API/Checksum.lua` documents *"v2: Ed25519 over canonical JSON"*, verified against a baked-in **platform public key** (`b531cb8b505ae9752b5b789f26085853b0ba5da5d7e7e244975f0545430d683a`). It attests that a sequence is the authentic published version of the author's work.

*Note for counsel:* the identical key appears in the GSE Companion's signed-directive engine — it is a genuine platform signing key, not a per-file checksum. GRIP reads it but stores it **inert** (`LegacyImport.lua` → `importMeta.sourceChecksum`), never verifies or surfaces it, and it is **absent from GRIP's exported/shared artifact** (confirmed by decoding a live LazyGrip GSE→GRIP conversion).

### (c) `PlatformID` — weakest standing alone; strong in company.
The GSE.Tools server-record identity bound to the author's account; preserved on rename, deliberately cleared on duplication so a copy "never resolve[s] to the same server record" (`GSE/API/Storage.lua`). Zero occurrences in GRIP.

*Defense:* an opaque sync key is a functional identifier, not information identifying the author to a human; GSE itself clears it on copy. *Response:* it need not be human-readable — § 1202(c)(5) covers "identifying numbers **or symbols**" — and its removal is now explained by the developers' own stated plan (Issue 2), not by function.

### Honest limit (unchanged and important)
**The human `Author` name is retained.** A defendant will argue the classic CMI — the author's name, § 1202(c)(2) — was never removed. *Response:* § 1202 protects the enumerated categories individually; removing the owner-record ID, the link to the owner's listing, and the platform signature is removal of CMI regardless of whether one other category survives. But expect this argument and do not overstate the claim: this is **not** an attribution-erasure case, it is a **provenance-linkage-removal** case. Framing it as "they cut my name off" is factually wrong and will be rebutted with GRIP's own code.

---

## Issue 2 — § 1202(b) and the double scienter

**Why the earlier "weak" rating no longer holds.** The prior draft assumed intent would have to be *inferred from the code*, and predicted the defense would win on "we dropped a key our schema has no field for." The contemporaneous record forecloses that:

| Element | Evidence (developers' own words) |
|---|---|
| Knew GSE protected the data | *"how to bypass the new GSE security system that wont allow import unless it includes some sort of secret stuff encoded by their gse tools website"* |
| Intended to remove the identifying data | *"Perhaps it would be easier for me to strip the gse tools stuff from gse"* |
| **Knew the content was licensed** | *"(I cant advise it since the GitHub is under **ARR Licence**)"* — the license named, with a disclaimer attached |
| Removal was the object, not a side effect | *"I'm worried you'll stop the conversation in addon. Or TL will do so much obfuscating that it makes it time prohibited"* |
| Executed | *"Kind of solved it"* — approx. four hours later; the capability ships in every release since |

This is direct evidence of both prongs. The "innocent format-conversion" explanation — the defense's best argument in the earlier draft — is contradicted by the developers' own words: they did not omit the fields because their schema lacked them; they set out to **strip** them in order to **bypass** a protection they knew guarded licensed content. GRIP's own source comment corroborates (`LegacyMigrate.lua`: *"newer source builds keep the runtime table private … otherwise migrate straight from SavedVariables"*).

*CoreLogic*'s "pattern of conduct / modus operandi" route — the memo's original best hope — is now backed by explicit statements rather than inference, and the conduct repeats across the addon, the LazyGrip decode tool, and the LazyGrip convert tool.

**Remaining honest limits.** (i) Whether `PlatformID` qualifies as CMI is still contestable — lead with `HelpURL`. (ii) The retained author name blunts a *Mango*-style "concealment of authorship" narrative; frame concealment as severing the work from its **verifiable ownership record**, not from the name. (iii) *CoreLogic* is Ninth Circuit — confirm the standard in the relevant forum. (iv) Discord quotes require authenticated provenance and timestamps to carry evidentiary weight.

**Assessment:** a **substantially stronger** § 1202(b) claim than the earlier draft allowed — better CMI (a link and a signature), and scienter that is documented rather than inferred.

---

## Issue 3 — Grokster inducement (likely the lead theory)

**The law.** *MGM Studios v. Grokster*, 545 U.S. 913 (2005): "one who distributes a device with the object of promoting its use to infringe copyright, as shown by **clear expression or other affirmative steps taken to foster infringement**, is liable for the resulting acts of infringement by third parties." Requires (1) an object of promoting infringing use, shown by clear expression/affirmative steps; and (2) **resulting acts of direct infringement** by third parties.

**Why it fits this record better than anything else.** The rights holder's framing — *"it's not about whether they did it; they wanted to, planned it, and executed it"* — is, in legal terms, inducement.

- **Clear expression of the unlawful object:** the Discord chain above. Stating the goal as bypassing another project's protection, proposing to strip the owner data, naming the ARR license while planning around it, then announcing success four hours later, is about as close to *Grokster*'s "clear expression" as a real record gets.
- **Affirmative steps:** the capability shipped, and has shipped in **every release from v1.0.4 through current v2.3.5** (`data/grip_version_scan.csv`); the same operator offers it publicly as a web service on LazyGrip.net.
- **The distributor's own licence says the restrictions must be observed — added in v2.4.8, 2026-08-25.** Section 6 of the rewritten `LICENSE` shipped in the current release states that sequences imported into or shared through the addon "are not part of the Work," that "rights in that content belong to whoever holds them," and that the user is responsible "for observing any restriction the author of that content has placed on it." Shipped in the same archive as code that removes `PlatformID` and `HelpURL` — zero references in that build — and performs no licence or copyright check anywhere in `Import/` or `Engine/`. **The significance is evidentiary, not admissive:** it establishes the distributor's contemporaneous knowledge that third-party restrictions attach to imported content, while the shipped code removes the field that conveys them. Full text and verification in `evidence/RELEASE-DELTA-ANALYSIS-2026-08-26.md` §3a.
- **Predicate direct infringement:** satisfied whenever a user runs the migration with the rights holder's All-Rights-Reserved sequences installed — that reproduction is an unauthorized copy. This element must be **pleaded**, not assumed. It is trivially satisfied, but it is not optional: capability + intent alone, with no resulting copy, is not infringement.

**Honest limits.** *Grokster* liability is not established by capability alone — *Sony Corp. v. Universal City Studios*, 464 U.S. 417 (1984) protects tools with substantial noninfringing uses, and a user migrating **their own** sequences is exactly such a use. What defeats a *Sony* safe harbor is evidence of unlawful **object** — which is what the Discord supplies. **Do not argue this by analogy to contraband** (a tool that is unlawful in itself): the analogy concedes *Sony*'s premise and invites the defence, because a macro sequencer plainly has substantial lawful uses. Argue object, not danger. **And on the v2.4.8 licence disclaimer specifically:** a term instructing the user to observe the author's restrictions does not shift the distributor's own responsibility — *Grokster* liability turns on the distributor's affirmative steps and expressed object, not on what the end user was told. Its evidentiary value runs the other way: it shows the distributor knew such restrictions existed and attached to imported content, in the same release whose code removes the field that conveys them. Counsel should expect it to be raised as a defence and should be ready to use it as evidence of knowledge instead. Expect a fair-use/interoperability defense on the import path.

---

## Bottom line / recommendation

1. **Lead with the conduct case, not the statute.** The strongest sequence is: *documented intent → shipped capability → resulting user copies of ARR content with the ownership linkage removed.* That is **inducement (Grokster)**, with **§ 1202(b)** alongside.
2. **Direct infringement + license breach remain the floor** — unauthorized reproduction and distribution (17 U.S.C. § 106(1),(3)) in breach of the SLG-Sequences license (2(a), 2(b), 2(d), 3). These need no CMI theory and no scienter showing.
3. **Plead the CMI in strength order:** `HelpURL` (link to owner's listing) → `Checksum` (platform Ed25519 signature) → `PlatformID` (owner record key).
4. **Do not claim source-code copying** — a full five-subsystem comparison disproves it (`grip-vs-gse-forensic-comparison.md`). **Do not claim § 1201 anti-circumvention** — the SavedVariables are plaintext on the user's own disk; this is not DRM circumvention. Both overreaches would damage the credible parts.
5. **The Discord record is the most valuable asset in this package.** Preserve it with authenticated timestamps and provenance. Its evidentiary integrity is worth more than any further code analysis.
6. **For CurseForge specifically:** the platform applies its own IP/moderation policy, not a court's standard. Documented intent + shipped capability is sufficient there. The Grokster/§ 1202 framing is for counsel and any court action.
7. **Verify every citation** before reliance, and confirm the CMI-definition split in the relevant circuit.

## Sources (for counsel to verify)
- 17 U.S.C. § 1202 — https://www.law.cornell.edu/uscode/text/17/1202
- *Stevens v. CoreLogic, Inc.*, 899 F.3d 666 (9th Cir. 2018) — double scienter; pattern-of-conduct
- *Mango v. BuzzFeed, Inc.*, 970 F.3d 167 (2d Cir. 2020) — concealment satisfies second scienter
- *MGM Studios v. Grokster, Ltd.*, 545 U.S. 913 (2005) — inducement
- *Sony Corp. v. Universal City Studios*, 464 U.S. 417 (1984) — substantial noninfringing use
