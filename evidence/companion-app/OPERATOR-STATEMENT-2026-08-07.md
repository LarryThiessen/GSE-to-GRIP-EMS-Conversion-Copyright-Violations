# Operator statement — GSE author, 2026-08-07 (the do-not-export stamp)

**Who:** Timothy Luke, author of GSE and operator of the GSE.Tools platform.

**Why this exists:** GRIP-EMS v2.3.17 (2026-08-01) introduced a do-not-share refusal keyed to a field called `noExport`. Searching GSE's shipped build and full source showed that field is **read 13 times and written zero times** — nothing in the GSE addon ever sets it. That left one question, answerable only by the platform operator: does GSE.Tools itself stamp the field? The answer decides whether GRIP's new gate has any effect at all. This is that answer.

**Provenance:** Discord direct message from **TimothyLuke** to the rights holder.

| Message ID | UTC (decoded from the snowflake) | Rendered locally |
|---|---|---|
| `1535242173153542154` | **2026-08-07 11:04:17.500 UTC** | 6:04 AM (rights holder's local time, UTC−5) |

> **This is a direct message, not a public channel.** The permalink is
> `https://discord.com/channels/@me/788975881678618644/1535242173153542154`. The `@me` segment
> means a DM between the rights holder and GSE's author — **a third party cannot open it**,
> unlike the server permalinks in `../discord/captures.md`, which anyone in the server can
> verify. The screenshot and the decoded message ID are the verifiable parts; the link is for
> the rights holder's own records. State this plainly wherever this statement is relied on.

**Screenshot:** `claim-screenshots/13_tim-operator-noexport-stamp-2026-08-07.png` — 714×79 px, SHA-256 `6c84d220de415eff1e6ed625b414b00e2b0e0b4191d6dd1005806b0056ea2431`. Shows the sender as **TimothyLuke**, the local time as **6:04 AM**, and the message text in full. The local time matches the snowflake-decoded UTC at UTC−5, which is the rights holder's offset — the two are independent of each other and agree.

---

## The statement

> everyone who is not the original authro gets a dont export stamp on it

*(Verbatim, including the original typo "authro".)*

---

## What it resolves

| Open question | Operator's answer |
|---|---|
| Does GSE.Tools stamp `noExport` on content held by someone other than its author? | **Yes.** Every copy held by a user who is not the original author carries the stamp. |
| Is the field therefore ever actually set, given the GSE addon never writes it? | **Yes — by the platform, not the addon.** The addon reads it; GSE.Tools applies it. |
| Can a GSE author set it on their own work? | **No, and they do not need to.** It is applied automatically to every non-owner copy. The absence of any write path in the addon (13 reads, 0 writes) is by design, not an omission. |

This also confirms the reading of GSE's own in-code comment, *"Protected/foreign content (noExport) is not owned by this user"* (`GSE_GUI/Editor_Tree.lua`): the flag marks a copy as belonging to someone else, and the platform is what marks it.

---

## What follows — verified in code, both sides

With the operator's answer supplied, the two import paths into GRIP can be traced end to end. They do not behave the same way.

### Path 1 — in-game Migrate: the stamp survives, and GRIP refuses

1. GSE.Tools stamps `MetaData.noExport` on the non-owner's copy (this statement).
2. GRIP's `Import/LegacyMigrate.lua` walks GSE's library and hands the **raw sequence object, MetaData intact**, to `LI.ProcessSequence(seqName, sequence, results, opts)`.
3. `LI.ProcessSequence` calls `LI.ResolveNoRedistribute(sequence)`, which reads `sequence.MetaData.noExport` and returns true.
4. `seqData.noRedistribute` is set.
5. `GE.IsNoRedistribute` refuses at **nine call sites** — four export rails in `Import/GRIPExport.lua`, five in `Engine/Transmission.lua` — ahead of construction, with *"no payload table, no encoded string, nothing for a caller to salvage."*

**On this path the protection works.** A third party who migrates a GSE library containing the rights holder's sequences into GRIP v2.3.17+ cannot re-export or re-share them. This is a genuine remedial improvement and is recorded as such.

### Path 2 — the LazyGrip.net converter: the stamp is not carried

Every module of the converter published at `github.com/lazygrip/lazygrip-gg` was searched for the field:

| Module | `noExport` / `noRedistribute` references |
|---|---|
| `src/lib/workshop/gseToGrip.ts` | **0** |
| `src/lib/workshop/gseDecoder.ts` | **0** |
| `src/lib/workshop/emsEncoder.ts` | **0** |
| `src/lib/workshop/gripEnvelope.ts` | **0** |
| `src/lib/workshop/gripExportEnrich.ts` | **0** |
| `src/app/api/workshop/decode/route.ts` | **0** |

The same converter was amended on 2026-07-30 (commit `8d541bc`) to carry `platformId`, `helpUrl`, `checksum` and `gseVersion` through conversion. **It does not carry the one field that stops redistribution.**

A stamped sequence put through that converter therefore emerges unstamped, and GRIP will export and share the result normally — the refusal at all nine sites never fires, because the field it reads is not present.

### The consequence, stated plainly

> **The addon refuses to redistribute a stamped sequence. The website's converter removes the stamp.**

The convert page was disconnected from the Workshop UI on 2026-08-06 (`ce4b75a`), but the same conversion remains reachable through the Build tool's import endpoint (`/api/workshop/import` → `importToBuilderModel` → `convertDecodedGSEToGRIP`), which has no `noExport` handling either.

---

## Correction this statement forces

An earlier working analysis in this package concluded that GRIP's do-not-share gate "will almost never fire," on the basis that nothing in GSE writes `noExport`. **That conclusion was wrong.** The addon does not write it; the platform does, on every non-owner copy. The gate fires on exactly the case the complaint describes — a user migrating a library containing another author's sequences.

Recorded here rather than quietly amended, to the same standard as the other corrections in this package. The corrected finding is narrower and better evidenced: the addon's protection is real and works on the migrate path, and it is defeated by the operators' own website on the conversion path.

---

## Standing caveats — do not drop these

1. **This is a statement, not an artifact.** It is the platform operator's own account of his own platform's behaviour, and it is authoritative in a way no client-side analysis can be — but it is testimony and should be presented as such. What *is* independently checkable is everything downstream of it: GRIP's handling of the field, and the converter's omission of it, both from published source.
2. **DM-sourced.** Message ID and decoded UTC are recorded above, to the same standard as `../discord/captures.md`. The one irreducible difference is that no third party can open the permalink. If this statement needs to carry weight with an outside party, ask GSE's author to restate it somewhere publicly checkable, or to confirm it to them directly.
3. **Screenshot saved and hashed.** `claim-screenshots/13_tim-operator-noexport-stamp-2026-08-07.png`, SHA-256 recorded above. Supplied by the rights holder 2026-08-07 as a zip from his own Discord client; the PNG's internal timestamp (2026-08-07 06:06 local) sits two minutes after the message's own decoded time, consistent with a capture taken on receipt.
4. **Scope of the answer.** The operator states that non-original-author copies are stamped. This exhibit does not extend that to any claim about *when* the stamp is applied, whether it can be removed on the platform, or how it interacts with the fork-approval flow — none of which were asked or answered.
5. **No motive is asserted** for the converter's omission of the field. The counts are recorded; the reader may draw conclusions.
