# 2026-05-28 — GRIP's provenance flag: operated, defeated, and dismissed

**Where:** House of Macros `#general`.
**Capture:** `13_2026-05-28_provenance-flag-pseudonym-recreate-and-dismissed.png`
**Why this exists:** the exchange shows GRIP's authorship-provenance system being described by the developer, then operated and dismissed by a user — in the same thread, within five minutes. It is the counterpart in plain English to the `Engine/Identity.lua` findings in `../../grip-cmi-evidence-exhibit.md`.

---

## The exchange, verbatim

**Sataana — 2026-05-28 2:54 PM:**

> "Honestly, I just want to get EMS to a so called finished state (which I doubt will ever happen) so I can get the to sequence generator work 😛"

**Sataana — 2026-05-28 2:58 PM** *(replying to Pershizzle, addressed to MFDOOM; message marked **(edited)**)*:

> "Regarding this @MFDOOM , Could this be, because you imported / migrated a GSE version and edited / forked that one? 😛
> In which case, unless I am mistaking, it will flag it as "edited by a not original user" 😅
> Cuz, EMS doesnt know that what ever you imported / migrated was made by you"

**MFDOOM — 2026-05-28 3:03 PM:**

> "nah i made the rotation with my original char for example my monk called Zpd. and if i change the option to pseudonym to MFDOOM itll say this sequence has been edited.
> can be recreated super easily, start a new rotation, add a few steps…
> i again dont give a shit about this, its literally a visual thing that 99% of people arent gonna even look at, they just wanna load in…"

*(MFDOOM's message continues past the captured frame.)*

---

## What each part establishes

### 1. The developer states GRIP cannot determine the origin of imported content

*"EMS doesnt know that what ever you imported / migrated was made by you."*

This matches the shipped code. `Import/LegacyImport.lua:870-879`, the GSE-legacy import path, sets:

```lua
seqData.originalAuthor     = seqData.author or "Unknown (GSE legacy)"
seqData.originalSignature  = ""
seqData.provenanceSource   = "gse-legacy"
seqData.signatureAlgorithm = "ALG_V0_DJB2"
```

An unsigned import with a name carried over from the source file. "Doesn't know" is an accurate description of that state.

### 2. The pseudonym option is real, and users operate it

*"if i change the option to pseudonym to MFDOOM itll say this sequence has been edited."*

`Engine/Identity.lua` implements exactly this: a per-sequence `privacyMode`, an account-level `config.pseudonym`, `I:GetDefaultAuthorChoice(privacyMode)`, and `I:StampOriginal(seq, chosenDisplayName)` which stamps whichever display name is selected while deriving `originalAuthorIdentity` from the account's own identity hash. A user here describes switching that setting and observing the resulting "edited" state.

### 3. The provenance flag can be cleared by recreating the sequence

*"can be recreated super easily, start a new rotation, add a few steps…"*

A method for removing the "edited by a not original user" marker: rebuild the sequence rather than import it, and it stamps as originally authored by the rebuilder. Described casually, as ordinary practice.

### 4. The marker is treated as cosmetic

*"i again dont give a shit about this, its literally a visual thing that 99% of people arent gonna even look at."*

This is the attitude toward the attribution marker, stated by a member of the group, in the group's own channel — the marker exists, its purpose is understood, and it is regarded as decoration.

### 5. A "sequence generator" is a stated next project

*"so I can get the to sequence generator work."* Not otherwise recorded in this package. Noted for follow-up; nothing further is claimed about it here.

---

## Scope — read before citing

1. **This is about GRIP's own provenance marker**, not about `PlatformID`, `HelpURL` or `Checksum`. Do not merge the two: the GSE.Tools CMI removal is a separate finding in `../../grip-cmi-evidence-exhibit.md`.
2. **Points 3 and 4 are MFDOOM's, not Sataana's.** MFDOOM is the House of Macros owner, not the GRIP developer. Attribute accordingly.
3. **"Recreated super easily" is a description of rebuilding a sequence**, which produces genuinely new authorship for content the rebuilder actually re-entered. It is only significant where the underlying steps came from someone else's work — which this message does not itself establish.
4. **No intent is claimed.** The exchange is recorded as it reads. Whether the provenance marker's weakness was designed, tolerated or simply unexamined is not determined here.
5. **The 2:58 PM message carries Discord's "(edited)" marker.** Disclosed for the same reason every edited or deleted message on either side is disclosed in this package.

## Provenance

Re-captured from Discord on 2026-08-01 after the original 2026-07-13 capture session's screenshot was found never to have been written to disk. The message text, authors and timestamps are as displayed in the client; the 2026-05-28 date resolves an entry previously logged in `captures.md` as "(date TBD)".
