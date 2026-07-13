# Analytical memo — Does GSE's `PlatformID` qualify as CMI, and is there a viable §1202(b) claim against GRIP-EMS?

> **THIS IS NOT LEGAL ADVICE.** I am not a lawyer and this creates no attorney–client relationship. This is a structured issue analysis prepared for the copyright holder to take **to** qualified counsel. Every case citation below must be independently verified by an attorney before any reliance. It is deliberately two-sided; it argues the defense's best points as well as the claimant's.

## Question presented

The GSE addon stamps each sequence with a `PlatformID` (a GSE.Tools server-record identity, tied to the author's account). GRIP-EMS imports GSE sequences, omits `PlatformID` while retaining the human-readable `Author` field, and re-exports/shares the result. **(1)** Does `PlatformID` constitute "copyright management information" (CMI) under 17 U.S.C. § 1202(c)? **(2)** If so, is there a viable removal/distribution claim under § 1202(b)?

## The law

**§ 1202(c) — definition.** CMI is enumerated information "conveyed in connection with copies … of a work," including: (2) the author's name and identifying information; (3) the copyright owner's name and identifying information; (4) terms and conditions for use; and **(5) "identifying numbers or symbols referring to such information, or links to such information."** Courts hold CMI is **not** limited to "automated copyright protection or management systems," and applies "regardless of the form in which that information is conveyed" (majority view, rejecting the narrow reading of *IQ Group v. Wiredccommerce*, 409 F. Supp. 2d 587 (D.N.J. 2006), and *Textile Secrets Int'l v. Ya-Ya Brand*, 524 F. Supp. 2d 1184 (C.D. Cal. 2007)). CMI has been held to include a photo file's **metadata**.

**§ 1202(b) — prohibited acts + double scienter.** No person shall, without authority, (1) intentionally remove or alter CMI, or (3) distribute works/copies knowing CMI has been removed — **knowing, or having reason to know, that it "will induce, enable, facilitate, or conceal" an infringement.** *Stevens v. CoreLogic, Inc.*, 899 F.3d 666 (9th Cir. 2018), established the **double-scienter** requirement: the plaintiff must show the defendant (a) knew CMI was removed without authority, **and** (b) knew or had reason to know the removal **will** — meaning *likely*, not merely *might* — induce/enable/facilitate/conceal infringement. *CoreLogic* **rejected** the § 1202 claim for failure of element (b), but noted a plaintiff can prove the requisite knowledge via a defendant's **"pattern of conduct" or "modus operandi."** The Second Circuit in *Mango v. BuzzFeed, Inc.*, 970 F.3d 167 (2d Cir. 2020), held that a defendant's awareness that distributing a work **without proper attribution** will **conceal his own infringing conduct** satisfies the second scienter prong.

## Application

### Issue 1 — Is `PlatformID` CMI?

**Arguments that it qualifies:**
- § 1202(c)(5) expressly covers **"identifying numbers or symbols referring to [author/owner] information, or links to such information."** `PlatformID` is, on its face, an identifying number that resolves to the author's GSE.Tools account record (which contains author/owner identity). This is the strongest textual hook.
- CMI is not confined to automated protection systems and applies regardless of form; a metadata identifier can qualify. `PlatformID` lives in the sequence's `MetaData` and travels **with** the work in GSE's export/save format — i.e., "conveyed in connection with copies of the work."
- GSE's own code treats `PlatformID` as an **ownership/identity** value, not a cosmetic one: it is preserved on rename and deliberately cleared on duplication so a copy "never resolve[s] to the same server record." That evidences its identity/attribution function.

**Arguments that it does not (defense):**
- `PlatformID` is an **opaque, functional database/sync key**, not information that *identifies the author to a human*. Several courts distinguish purely technical/functional identifiers from CMI. A court could hold it is a routing token, not "information … identifying the work [or] author."
- The (c)(5) "**links to such information**" theory requires the number to point to conveyed CMI. Here the author-resolution happens **server-side** (GSE.Tools/`personaAuthor`); that mapping is not itself conveyed with the distributed work, weakening the "link" characterization.
- **Decisive-feeling point:** the classic, unambiguous CMI — the **author's name** (§ 1202(c)(2)) — is **retained** by GRIP (it copies `Author`). The most obvious CMI is therefore *not* removed at all. That substantially undercuts a narrative that "CMI was stripped."

**Assessment:** `PlatformID` is *plausibly* CMI under (c)(5) — the claim is colorable and not frivolous — but it sits at the contested edge of the definition (functional identifier vs. identifying information), and the retention of the author name is a real problem for the framing.

### Issue 2 — § 1202(b) removal/distribution + double scienter

**Removal / distribution (elements (b)(1)/(b)(3)):**
- *For:* GRIP omits `PlatformID` entirely on import (documented across all 64 releases) and distributes the re-encoded sequence without it via export + P2P. If `PlatformID` is CMI, that is non-carriage on a distributed copy.
- *Against:* GRIP will argue it did not "remove CMI **from a copy of the work**"; it read the user's installed data and authored a **new record in its own schema** that has no field for GSE's server key. Omission-on-conversion is arguably not the targeted "removal" § 1202(b)(1) contemplates, and the distributed artifact is a GRIP-format derivative that still bears the author name.

**Double scienter (the hardest element — where *CoreLogic* claims fail):**
- **Prong (a) — knowledge CMI was removed without authority:** GRIP records the **source GSE version** per sequence (`importMeta.sourceVersion`), so it knows the content is GSE-authored. But knowledge that it is *removing CMI without authority* is weaker — `PlatformID` is undocumented server metadata, not an obvious attribution mark.
- **Prong (b) — knowledge removal "will" conceal/facilitate infringement:** **This is the claim's central weakness.** Under *CoreLogic*, "will" means *likely*, not *might*; and because GRIP **retains the visible author name**, it is hard to argue the removal *conceals authorship* the way *Mango* required (there, attribution was stripped and the defendant's own infringement concealed). GRIP's defense — "we dropped a sync key we have no field for; the author's name rides along; nothing is concealed" — is strong on this prong.
- **Claimant's best counter:** the *CoreLogic* "**pattern of conduct / modus operandi**" route. GRIP built a **systematic** pipeline — detect GSE, force-decompress GSE's library, bulk-copy every sequence, record its GSE origin, drop the ownership ID, and enable free re-share — repeated across 64 releases. A fact-finder could infer awareness that this design predictably facilitates unauthorized redistribution of others' licensed sequences. This is the argument most worth developing with counsel, ideally supported by any evidence GRIP was **told** its imports were carrying creators' gated/licensed content and continued.

**Assessment:** A **colorable but not strong** § 1202(b) claim. It can survive a "CMI can be an identifying number" challenge in theory, but the **double-scienter** prong — the same element that sank *CoreLogic* — is a serious obstacle here because the author name is retained.

## Bottom line / recommendation

1. **§ 1202 should be pleaded as a supporting count, not the spearhead.** The qualification of `PlatformID` as CMI is arguable, and the § 1202(b) double-scienter is a real hurdle given the retained author name.
2. **The stronger, cleaner claims are ordinary copyright infringement and breach of license:** unauthorized **reproduction and distribution** of the sequences, which are published **"All Rights Reserved"** on CurseForge under the SLG-Sequences license (no redistribution / no derivatives / no removal of attribution — clauses 2(a),(b),(d), 3). These do **not** require the CMI characterization or the double-scienter showing.
3. **For a CurseForge complaint specifically:** CurseForge adjudicates **copyright infringement and license/IP-policy violations**, not § 1202 nuance. **Lead the CF complaint with infringement + All-Rights-Reserved license breach**; keep § 1202 for a demand letter or federal action where a court applies it.
4. **To strengthen § 1202 with counsel:** (a) develop the *CoreLogic* pattern-of-conduct theory from the systematic import→strip→reshare design; (b) gather any communications showing GRIP knew its imports carried third-party licensed/gated sequences; (c) consider whether a captured GRIP export of your own sequence (test content only) helps show a distributed copy with the identifier gone.
5. **Verify every citation.** Confirm *Stevens v. CoreLogic*, 899 F.3d 666 (9th Cir. 2018) and *Mango v. BuzzFeed*, 970 F.3d 167 (2d Cir. 2020), and the current state of the CMI-definition split in the **relevant circuit**, before relying on anything here.

## Sources (for counsel to verify)
- 17 U.S.C. § 1202 — https://www.law.cornell.edu/uscode/text/17/1202
- *Stevens v. CoreLogic, Inc.*, 899 F.3d 666 (9th Cir. 2018) — double-scienter; pattern-of-conduct — https://law.justia.com/cases/federal/appellate-courts/ca9/16-56089/16-56089-2018-06-20.html
- *Mango v. BuzzFeed, Inc.*, 970 F.3d 167 (2d Cir. 2020) — concealment-of-own-infringement satisfies second scienter
- Practitioner summaries — https://www.thowardlaw.com/2021/05/section-1202b-of-the-dmca-requires-scienter-for-cmi-claims ; https://www.troutman.com/insights/copyright-management-information-the-intellectual-property-you-didnt-know-you-have/
