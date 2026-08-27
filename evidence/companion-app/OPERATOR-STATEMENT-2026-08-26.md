# Operator statement — GSE author, 2026-08-26

**Who:** Timothy Luke, author of GSE and operator of the GSE.Tools server.

**Why this exists.** GRIP-EMS v2.4.8 shipped 2026-08-25 and this package needed to establish
what it does and does not now honour. The **server operator and addon author tested it himself**
and reported the result. His account and this package's independent code reading agree — see
"Two independent verifications" below.

**Provenance.** Direct messages to the rights holder, captured in
`claim-screenshots/`. **Verbatim below, including original typos.**

| Message ID | UTC (decoded from the snowflake) | Local (UTC−5) |
|---|---|---|
| `1542341163472781402` | **2026-08-27 01:13:08.685 UTC** | 2026-08-26 8:13 PM |
| `1542341566968897586` | **2026-08-27 01:14:44.886 UTC** | 2026-08-26 8:14 PM |

The two messages are **96 seconds apart**. Both timestamps are decoded from the message IDs
themselves, to the same standard as `../discord/captures.md`. The screenshots render them as
8:13 PM and 8:14 PM in the rights holder's local time (UTC−5); the authoritative UTC date is
therefore **2026-08-27**, the day after the local date this file is named for. Same convention,
and same DM channel, as `OPERATOR-STATEMENT-2026-07-29.md`.

> **These are direct messages, not a public channel.** The permalinks are
> `https://discord.com/channels/@me/788975881678618644/1542341163472781402` and
> `…/1542341566968897586`. The `@me` segment means a DM between the rights holder and GSE's
> author — **a third party cannot open these links**, unlike every server permalink in
> `../discord/captures.md`. The screenshots and the decoded IDs are the verifiable parts; the
> links are for the rights holder's own records. State this plainly wherever this statement is
> relied on.

**Disclosed for completeness:** the second message carries Discord's **"(edited)"** marker — it
was modified after posting. The text below is the message as it stands in the capture. This
package flags edited and deleted messages wherever they appear on either side, and does not make
an exception here.

**Context.** The second message is a reply to the rights holder, whose quoted line appears above
it in the capture: *"I checked it also - he ignores the PlatID and Licensing still"*.

---

## The statement

> yeah but hes back as of yesterday.  yesterdays release honours the no export and wont convert
> the gse.tools exports.  i checked it yesterday

> of the stuff that is exported from teh game (or copied from your personal gse.lua file).  Of
> the stuff exported from gse.tools that has the updated encryption he is not touching that
> stuff *(edited)*

---

## Two independent verifications, reached separately

The operator tested the shipped addon in the game. This package read the shipped Lua. **Both
reached the same finding on the same day, without reference to each other.**

| Operator's account (testing) | This package's finding (code, verified 2026-08-26) |
|---|---|
| "honours the no export" | `Import/LegacyImport.lua:628` — `LI.ResolveNoRedistribute` reads `sequence.MetaData.noExport` and returns true when set |
| "wont convert the gse.tools exports… that has the updated encryption" | `Data/Defaults.lua:946` defines `GSE3_ENCRYPTED_PREFIX = "!GSE3!+"`, commented *"protected/subscriber-only; not importable"*; `Import/Serialization.lua:93` refuses it **before any decode is attempted**, writes nothing, and returns a clear user-facing message. Enforced at **eight call sites** across `ImportPreview.lua`, `LegacyImport.lua` and `LegacyMigrate.lua` |
| "of the stuff that is exported from teh game (or copied from your personal gse.lua file)" — i.e. that path is still converted | Plain `!GSE3!` still imports. `Import/LegacyImport.lua:849-857` builds `importMeta` preserving `sourceVersion` and `sourceChecksum` from `MetaData`, while `PlatformID` and `HelpURL` remain at **zero references across all 220 Lua files** |

This is the strongest form of corroboration available here: a black-box functional test by the
affected platform's operator, and a white-box reading of the shipped source, agreeing on both
what was fixed and what was not.

## What it establishes

**The GSE.Tools protected path is genuinely closed.** Sequences exported through GSE.Tools with
the current encryption cannot be imported by GRIP-EMS. This is a real protection, it is
credited in `../PROVENANCE.md`, and the package does not dispute it.

**The unprotected path is unchanged.** Raw in-game exports, and sequences copied from a user's
own `GSE.lua`, still convert — and the owner identifier is still discarded on import.

**Why that still matters, and it is not a lesser claim.** Copyright subsists on creation;
17 U.S.C. §102 requires no registration, no notice and no technical protection measure. §1202
protects *information*, and its removal is actionable irrespective of whether the work was ever
encrypted — the provision keyed to technical measures is §1201, which this package expressly
declines to plead. **An author cannot be required to adopt a third party's platform in order to
have their All-Rights-Reserved licence observed.** As shipped, an author who exports from the
game — the ordinary case, and the only route open to someone without a GSE.Tools account — has
the field identifying them as owner dropped. Full argument:
`../RELEASE-DELTA-ANALYSIS-2026-08-26.md` §3b.

## Standing caveats — do not drop these

1. **This is a statement, not an artifact.** It is the operator's own account of a test he ran.
   It is authoritative in a way no third party's reading can be — he wrote the format being
   refused — but it is testimony. Present it as testimony, with the code citations above as the
   independently checkable part.
2. **Captured, but DM-sourced.** Screenshots, both message IDs and snowflake-decoded UTC are all
   recorded above — the same standard as `../discord/captures.md`. The irreducible difference:
   these are **DMs**, so no third party can open the permalinks. Verification rests on the
   screenshots and the decoded IDs. If this statement needs to carry weight with an outside
   party, ask GSE's author to restate it somewhere publicly checkable, or to confirm it to them
   directly.
3. **"Yesterday" means v2.4.8, released 2026-08-25.** The operator's local-time "yesterday" from
   a 2026-08-26 evening message. Do not read it as any later build. If a further release ships,
   this statement does not carry forward to it and the check must be run again.
4. **The second message was edited.** Flagged above. The pre-edit text is not available.
