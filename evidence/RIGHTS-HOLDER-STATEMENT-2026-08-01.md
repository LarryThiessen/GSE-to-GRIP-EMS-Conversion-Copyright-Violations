# Rights-holder statement — the GSE.Tools permission model, 2026-08-01

**Who:** Larry A. Thiessen ("ScaryLarryGames" / "SLG"), author and copyright owner of the SLG-Sequences macro sequences.

**Why this exists:** the complaint turns on what the removal of `PlatformID` actually *does*. Every other exhibit in this package establishes the removal itself — from GRIP's own shipped Lua, checkable line by line by anyone. What no amount of code reading can establish is what that identifier was holding in place on the platform side. Only the rights holder can state how his own works are configured, and what he has and has not permitted. This is that statement.

**Status of this document:** it is **testimony, not an artifact.** It is authoritative as to what I did with my own works, in a way no third party can verify by inspection, and it is offered as such. Where it describes how the GSE.Tools *platform behaves*, that is **not the impression of an outside user — I was involved in setting up this permission model on the platform**, and I am describing a system I helped establish and have used as an author ever since. It remains testimony, and independent confirmation is still recorded below as worth having, but the basis is participation, not inference.

---

## The statement

1. **Every sequence I have authored is flagged Private on GSE.Tools. 100%, without exception, and always has been.** There is no subset of my work that is public on that platform. This applies to every supporter, every subscriber, and every person who has ever downloaded anything of mine.

2. **Private does not mean invisible.** A Private sequence of mine may be placed in a **Public Collection**. That controls *reach* — it allows other users to find and **import** the sequence. It does not grant them any right to redistribute it, and it does not make it public in the copyright sense.

3. **Another user may store one of my sequences in their own GSE.Tools library. They cannot pass it on.** When one of my sequences is held in another user's library, the **Export and Install controls are not available to them.** They can keep it and use it. They cannot hand it to anyone else through the platform.

4. **To do anything further, they must request a fork, and I decide.** A fork request comes to me as the original author. **I approve it or I refuse it.** That approval step is the entire mechanism by which my permission is sought and given.

5. **I have never approved a fork request for the GRIP-EMS project, its developer, LazyGrip.net or its operators, or for anyone acting for them. No such request has ever been made to me.** The consent step exists, it functions, and it has never been used by any of them.

6. **`PlatformID` is the token that makes points 3 and 4 possible.** It is how GSE.Tools identifies a given sequence as mine and applies the restrictions above to it. It is not a label and it is not decorative — it is the handle the platform holds the work by.

7. **Therefore, what the removal of `PlatformID` does is not "lose attribution."** It takes the work *out of the system that was withholding Export and Install*, and it removes the fork-approval step at which my permission would have had to be asked. A sequence of mine that has passed through that removal is no longer subject to any of the controls in points 3 and 4. That is the injury, and it is the reason the identifier matters to this complaint.

---

## What this establishes, and what it does not

| Point | Basis | Independently verifiable? |
|---|---|---|
| All my sequences are Private | My own configuration of my own account | **Only by me** — no third party can inspect my settings. This is testimony. |
| I have never approved a fork request for any GRIP-EMS-related party | My own record of my own approvals | **Only by me.** Testimony. |
| A Public Collection controls reach, not redistribution | **Involvement in setting up the model**, and use as an author since | **Needs confirmation** — see below |
| A stored Private sequence shows no Export or Install control | **Involvement in setting up the model**, and use as an author since | **Needs confirmation** — see below |
| A fork request routes to the original author for approval | **Involvement in setting up the model**, and use as an author since | **Needs confirmation** — see below |
| `PlatformID` is the identity GSE.Tools resolves a sequence by | GSE's own shipped source, cited in `../grip-cmi-evidence-exhibit.md` §3 | **Yes** — `GSE/API/Storage.lua`, `GSE/API/SequenceDelta.lua` |
| GRIP omits `PlatformID` on import and never carries it | GRIP's own shipped source | **Yes** — zero references across v1.0.4, v1.9.1, v2.3.5 and v2.3.16 |

## Open — do not present the platform behaviour as verified until one of these exists

Points 2, 3 and 4 describe how **GSE.Tools behaves**, not what I did. I was involved in setting that model up, so this is not guesswork — but for an outside reader a platform's mechanics land harder from the operator, or from a screenshot of the controls, than from any statement however well founded. **That is a point about who is reading it, not about whether the description is right.** Any one of the following would settle it, and until then this document should be relied on for the conduct points and cited as a rights-holder account for the mechanics:

1. **A statement from Timothy Luke**, who operates GSE.Tools — the same standing as `companion-app/OPERATOR-STATEMENT-2026-07-29.md`, which is the precedent for this in the package. He is the only authority on how the platform actually gates Export, Install and forks.
2. **A screen capture** of one of my Private sequences held in another user's library, showing the Export and Install controls absent or disabled — the mechanism visible rather than described.
3. **GSE.Tools' own documentation** of the fork-approval flow.
   **Status: requested.** As at 2026-08-01 the rights holder has asked **Timothy Luke** to point him at where this behaviour is documented, and will supply the reference when he receives it. This is the expected route to closing points 2–4, and it is expected to close them rather than change them — the rights holder's position is that he knows the platform works as described, having used it as an author throughout.

   > **When the documentation arrives, add it here and update the three "Needs confirmation" rows in the table above.**
   >
   > - Source / URL: `__________`
   > - Supplied by: `__________`  Date: `__________`
   > - Which of points 2, 3 and 4 it covers: `__________`

Option 3 is now in motion. Option 2 is the cheapest fallback and needs one cooperating user. Option 1 — a direct statement from the platform operator — remains the strongest, and options 1 and 3 may well arrive together.

## Caveats — do not drop these

1. **Testimony, not reproducible evidence.** Present it as the rights holder's account, in the way the operator statement is presented as the operator's account. Do not describe it as proven.
2. **The complaint does not collapse without it.** The reproduction, the omission of `PlatformID`, and the redistribution path are all established from shipped code and stand on their own. This statement explains *why the omission matters*; it is not load-bearing for the fact that the omission occurs.
3. **This corrects an earlier statement of mine.** Earlier versions of the complaint and exhibit said roughly 80% of my sequences were distributed privately to supporters. That figure described distribution *reach* and was misleading as to *permissions* — the Private flag is universal, not partial. Corrected across the package on 2026-08-01, and recorded here rather than quietly amended.

**Signed:** Larry A. Thiessen ("ScaryLarryGames")
**Date:** 2026-08-01
