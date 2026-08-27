# The Reddit exchange — ScaryLarryGames ↔ JesperLive, 2026-06-10/11

**Captured 2026-08-26** from `old.reddit.com`, logged in as the rights holder, via the
comment JSON tree (`/comments/1u25ulq/.json?sort=old&limit=500&depth=20`) and confirmed
against the rendered permalink page.

**Why this file exists.** The `correspondence/2026-07-cf-claim-thread.md` correction of the
same date needed to establish whether the developer's side of the channel was open before
2026-08-26. It was. This is the exchange.

---

## The thread

| | |
|---|---|
| **Post** | *"GSE is breaking WoW EULA and Banning Paying Supporters (Accessibility Addon)"* |
| **Submitted by** | `zulubyte` |
| **Date** | 2026-06-10 ("2 months ago" as displayed 2026-08-26) |
| **Subreddit** | r/wow |
| **Score** | 393 points, 91% upvoted, 114 comments |
| **Link** | https://www.reddit.com/r/wow/comments/1u25ulq/gse_is_breaking_wow_eula_and_banning_paying/ |

> **Note on the thread ID.** This is **not** `1urdvdj` (*"We Need to Talk About the GSE Addon
> Community"*, 2026-07-08, also by `zulubyte`). That thread was checked first on 2026-08-26 —
> its full comment tree is **78 comments and contains neither `ScaryLarryGames` nor
> `JesperLive`**. The exchange is in `1u25ulq`. Both threads are `zulubyte` posts about GSE
> three weeks apart, which is the likely source of the mix-up.

---

## The four comments

| # | Author | ID | UTC | Score | Parent |
|---|---|---|---|---|---|
| 1 | `JesperLive` | `oqvo8jt` | 2026-06-10 17:47:54 | **+145** | top-level |
| 2 | **`ScaryLarryGames`** | `oqwzfcb` | 2026-06-10 21:20:26 | **−24** | top-level |
| 3 | **`JesperLive`** | `oqycqr4` | 2026-06-11 01:47:28 | **+195** | **reply to `oqwzfcb`** |
| 4 | `JesperLive` | `oqyicgy` | 2026-06-11 02:18:27 | +14 | reply to his own `oqvo8jt` |

**Comment 3 is the reply.** It is a direct child of the rights holder's comment, posted
**4 hours 27 minutes** after it, and it is **locked** (as is the rights holder's own comment
and much of the thread — the moderators locked it, not either party).

Permalinks:
- Rights holder: https://www.reddit.com/r/wow/comments/1u25ulq/gse_is_breaking_wow_eula_and_banning_paying/oqwzfcb/
- Developer's reply: https://www.reddit.com/r/wow/comments/1u25ulq/gse_is_breaking_wow_eula_and_banning_paying/oqycqr4/

---

## Does it quote him?

**Not as Reddit block-quotes.** A programmatic check of the reply body found **zero lines
beginning with `>`**. It quotes him **inline, in quotation marks**, repeatedly — the section
headings are built out of his words:

- *On "took the GSE addon and ran it through Claude" and "fucking thiefs"*
- *On "GSE is free, period" and "a small Patreon version… one or two quality of life things"*
- *On "not because of… what addon you are using"*

and a section headed **"Things your own comment settles"** which lists three of the rights
holder's own phrases back to him, each introduced with *"your words:"*.

**This matters for how it is described.** The statement "he replied there, quoting him" is
**correct in substance** — the reply is addressed to the rights holder, is a direct child of
his comment, and reproduces his phrases throughout. It is not a Reddit-style quote-reply.
Describe it as a reply quoting his words inline.

---

## What the reply establishes for this package

**The channel was open, from his side, on 2026-06-11.** He answered the rights holder
publicly and at length (7,214 characters). This is the point the CurseForge correction rests
on: the submission's stated reason for not contacting the other party first — that the
developer had closed the channel — is unsupported, and the direction was in fact the reverse.

**He states he will not reply again.** The reply opens *"This is the only reply I'll give
you. I'm not doing rounds of this"* and closes *"I won't be replying again."* That is a real
qualification on "the channel was open" and should be recorded alongside it: it was open
once, by his own framing, and he declared it closed at the end of the same comment.

**He answers the copying allegation.** He states EMS and GSE ship as readable Lua, that he
diffed them, and that the overlap is generic WoW API boilerplate plus standard AceComm
callbacks — *"No copied logic."* He describes the converter as an importer for a user's own
strings. **This is consistent with this package's own finding**: the five-subsystem forensic
comparison in `../../grip-vs-gse-forensic-comparison.md` **disproves source-code copying**,
and the memo already instructs counsel not to plead it. His account and this package's
technical finding agree on that point.

**It does not address the CMI claim.** Nothing in the reply addresses `PlatformID`,
`HelpURL`, or the removal of owner-identifying fields from sequence strings — the actual
subject of this complaint. He argues about code copying, the Patreon build, and the
Companion app. The §1202 conduct is untouched.

**Most of the reply is counter-allegation, not defence.** Roughly two-thirds concerns
(a) GSE's paid Patreon build versus Blizzard's UI Add-On Development Policy point 1, and
(b) the GSE Companion app's `detectGripEmsAcrossClients` / `syncRestrictedAccountFlag` /
`purgeGripCharSequences` functions. Those are Part A of this package's own subject matter and
are already analysed in `../companion-app/COMPANION-FORENSIC-FINDINGS.md`, which reached
**substantially the same technical findings independently** — and in
`../companion-app/OPERATOR-STATEMENT-2026-07-29.md`, in which the GSE author states there was
no server-side `enforce` capable of being set true and that the endpoint was a dead end he did
not own. **Read those two files together with this one.** They are the answer to this section
of the reply and they are already in the package.

**Cross-reference.** The Reddit gallery he cites (`postimg.cc/gallery/fXFPBtm`, "image 18",
"image 19") is the 17-screenshot gallery captured in the Bellular Warcraft video review at
9:06 — see `C:\Git\Image-Vault\dmca-u37h_2yliyY\TIMESTAMPS.md`.

---

## Verification

Anyone can reproduce this. Open either permalink above. Or fetch the tree:

```
https://old.reddit.com/comments/1u25ulq/.json?sort=old&limit=500&depth=20
```

and locate comment IDs `oqwzfcb` (rights holder) and `oqycqr4` (the reply, `parent_id`
`t1_oqwzfcb`). Reddit's public JSON returns HTTP 403 to unauthenticated server-side clients;
fetch it from a logged-in browser session.

**Both comments are locked and both are still live as at 2026-08-26.** Locked comments cannot
be edited or replied to, but they can still be deleted by their authors. Archive them.

---

## Captures

Taken **2026-08-26** with Playwright against `www.reddit.com` (signed out — both comments are
publicly visible), at full device-pixel resolution.

**These images are committed to this repository on purpose.** Both comments are locked, but a
locked comment can still be deleted by its author, and the account itself can be deleted. If
either happens, the permalinks in this file go dead and a reader who came looking for the
exchange would find nothing. The images are the copy that survives that. They live in
`captures/` beside this file, and a second copy is held outside version control in the image
vault at `C:\Git\Image-Vault\grip-evidence\`.

| File | What it shows |
|---|---|
| `captures/30_jesperlive_2026-06-11_reply-to-SLG_full-thread_oqycqr4.png` | Whole thread, 1280×15503 px, with the reply highlighted in place — establishes where it sits among 114 comments |
| `captures/31_jesperlive_2026-06-11_reply-to-SLG_comment-only_oqycqr4.png` | **The reply alone**, 545×2815 px — full text, **+195**, lock icon, timestamp, Sources list. The legible one. |
| `captures/32_scarylarrygames_2026-06-10_comment-he-replied-to_full-thread_oqwzfcb.png` | Whole thread with the rights holder's comment highlighted |
| `captures/33_scarylarrygames_2026-06-10_comment-he-replied-to_comment-only_oqwzfcb.png` | **The rights holder's comment alone** — full text, **−24**, lock icon, timestamp |

Both forms of each are kept deliberately: the full-thread image proves placement and that
nothing around it was cropped away; the comment-only image is the one a reader can actually
read.

**Capture notes, so the method is reproducible.**

1. `old.reddit.com` returns **HTTP 403** to Playwright; `www.reddit.com` serves normally.
   Reddit's public `.json` endpoints also return 403 to server-side clients. The comment tree
   used for the metadata in this file was read from a **logged-in browser session**; the images
   were then taken **signed out**. That order is deliberate — signed-out capture proves the
   comments are publicly visible to anyone, not surfaced only to the rights holder's account.
2. A floating search overlay from Reddit's own interface crosses one band of
   `31_..._comment-only_...png`. It is a page element, not a redaction. The text it overlaps is
   fully visible in `30_..._full-thread_...png` and in the record above.
3. Nothing in these images has been edited, cropped or annotated.
