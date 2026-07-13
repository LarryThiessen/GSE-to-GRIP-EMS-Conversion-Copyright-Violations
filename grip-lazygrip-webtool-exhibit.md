# Exhibit — LazyGrip.net Workshop web tools: on-demand reproduction of GSE sequences and server-side removal of GSE.Tools CMI

> **NOT LEGAL ADVICE.** Prepared by the rights holder for qualified counsel. Two-sided by design. Captured 2026-07-12. All findings below are reproducible from the files in `evidence/lazygrip-webtool/`.

## What this exhibit adds (and how it differs from the excluded "hosting" angle)

The README correctly excludes a **"lazygrip.net hosts redistributed copies of my sequences"** claim — that was investigated and returned zero matches. **This exhibit does not revive that claim.** It documents a *different* vector: the **function of LazyGrip's public "Workshop" web tools**, which on demand (a) reproduce a submitted GSE sequence in full plaintext, and (b) strip GSE.Tools identity/provenance information (CMI) when converting it to GRIP format. This is about what the tools *do to a submitted work*, not about hosting a library of the author's works.

## Operator / nexus to GRIP-EMS

- Site: `https://lazygrip.net` — self-described "community library for sequences built around" GRIP-EMS.
- Workshop tools page (`/workshop`) is titled **"Tools by Beard3d_Gamer"**, "integrated on LazyGrip by Slowdog." "Slowdog" is a listed author on the site and, per the site's own attribution, associated with GRIP-EMS. (Operator identity to be confirmed by counsel via WHOIS / CurseForge project ownership for GRIP-EMS project 1489414.)
- The tools accept and emit the GRIP-EMS native formats `!EMS1!` and `!GRIP1!` alongside GSE's `!GSE3!`.

## Method (reproducible; matches the package's decode recipe)

Both GSE (`!GSE3!`) and GRIP-EMS (`!GRIP1!`, `!EMS1!`) use the identical container:

```
CBOR  ->  raw DEFLATE  ->  Base64  ->  "!PREFIX!"
```

Decode = strip prefix → Base64-decode → raw-inflate (`zlib.decompress(data, -15)` / `pako.inflateRaw`) → CBOR-decode. This requires **no game client and no addon**. The decode is deterministic: a corrupted copy will not decode, so a clean decode proves the captured data is faithful to the original. The evidence JSON files were produced this way.

---

## Finding 1 — The Decode Export tool reproduces the full copyrighted macros in plaintext

Submitting the rights holder's own `!GSE3!` export (collection "SLG-DK-BLD", 4 sequences) to LazyGrip's **Decode Export** tool (`/workshop/decode`) renders the complete sequence — **every macro line in readable plaintext** — in the browser (e.g. sequence SLG-DK-BLD: `/castsequence [@player] reset=target Death's Caress, Death and Decay, Blood Boil, Death Strike, Blood Boil, Rune Strike`, `/cast Reaper's Mark`, `/cast Marrowrend`, etc.).

> **Screenshot:** `screenshots/decode-export-SLG-DK-BLD-macros.png` — the Decode Export view showing the rights holder's SLG-DK-BLD macro steps in full.

**Significance (claimant):** the tool does not merely convert — it **reproduces and displays** the protected expression on demand. A converted output string is not even required to obtain the work; the decoder hands over the macros verbatim. Relevant to the reproduction right (17 U.S.C. §106(1)) and the license's no-reproduction / no-derivative terms.

**Significance (defense / honest limit):** the reproduction is **user-initiated** — a user must paste the export string; the tool does not go find the author's works. This is tool functionality applied to user-supplied input, closer to a decoder/viewer than to a distribution.

---

## Finding 2 — The Decode step drops GSE.Tools CMI (on the rights holder's own content)

- Input: `evidence/lazygrip-webtool/00_original_gse_string.txt` (the rights holder's real GSE.Tools export).
- Faithful decode: `evidence/lazygrip-webtool/01_original_decoded.json`.

The **original** carries, in each sequence's `MetaData`, the full GSE.Tools identity set:

| Field | Value (sequence SLG-DK-BLD) | Type |
|---|---|---|
| `PlatformID` | `69e6f76961cd20b1721993cb` | GSE.Tools record ID |
| `HelpURL` | `https://gse.tools/sequences/69e6f76961cd20b1721993cb` | **URL link to the author's canonical listing** |
| `Checksum` | `v2:7870VPC5ZaoJkFtHdx7228JEd8TVE5dxMKpNSx1WgOEp…` | integrity/tamper signature |
| `GSEVersion` | `3323` | format stamp |
| `Author` | `ScaryLarryGames` | author name |

(All four sequences carry the same field set with their own IDs — see `01_original_decoded.json`.)

Posting that same string to LazyGrip's own decode endpoint — `POST https://lazygrip.net/api/workshop/decode` (HTTP 200) — returns a normalized structure that retains `author: "ScaryLarryGames"` but **carries no `PlatformID`, no `HelpURL`, no `Checksum`, no `GSEVersion`, and no `gse.tools` reference anywhere in the response.** The GSE.Tools identity is discarded at the decode stage.

---

## Finding 3 — The Convert-to-GRIP transform strips the CMI (demonstrated before/after)

The rights holder's own collection could **not** be converted: the Convert-to-GRIP tool returned *"Sequence 'SLG-DK-Oh-!@#$' has no convertible macro blocks"* (and likewise for "SLG-DK-GetOverHerE"), halting the whole collection.

> **Screenshot:** `screenshots/convert-to-grip-refusal-SLG.png` — Convert to GRIP refusing the rights holder's collection by name.

Because no GRIP-format output of the rights holder's own sequence could be produced, the strip is demonstrated on a **third-party** sequence that does convert, run through the same live tool:

- Before (GSE input, decoded): `evidence/lazygrip-webtool/02_thirdparty_BEFORE_gse.json` — `MetaData` contains `PlatformID: 6a1e0c0c61091862681b3c31`, `HelpURL: https://gse.tools/sequences/6a1e0c0c61091862681b3c31`, `Checksum: v2:hUaYE_03JAL…`, `GSEVersion: 3319`.
- Output string LazyGrip returned: `evidence/lazygrip-webtool/04_thirdparty_grip_output_string.txt` (a `!GRIP1!` string).
- After (that output, decoded): `evidence/lazygrip-webtool/03_thirdparty_AFTER_grip.json` — **`PlatformID`, `HelpURL`, `Checksum`, `GSEVersion`, and every `gse.tools` link are absent.** Author name and free-text notes survive.

This is a direct before/after showing the Convert-to-GRIP transform removes the GSE.Tools identity/provenance set while retaining the author name.

---

## Finding 4 — Where the gate lives, and who can use it

- **Server-side.** The `"no convertible macro blocks"` error string appears **nowhere in the site's client JavaScript** (all chunks searched); it is generated by LazyGrip's server. Decode and convert are both server API calls (`/api/workshop/decode`, `/api/workshop/convert`).
- **Login-only, no tier.** The decode page redirects unauthenticated users to `/auth/login`; any authenticated account can use the tools. Searches for role/pro/plan gating in the client returned only false positives (React internals `isPropagationStopped`, ARIA `role`). No evidence of a paid tier or role restriction on decode/convert.
- **Consequence:** the reproduction-and-strip capability is available to **every logged-in LazyGrip user**, on any GSE export string they possess. The refusal on the rights holder's specific sequences is a **content-based** server rule ("no convertible macro blocks" depends on what is in the sequence), applied uniformly — **not** a per-user permission. (Whether LazyGrip's server also applies undisclosed per-account overrides cannot be determined from the client and is unknown.)

---

## Legal relevance (for counsel — two-sided)

**Strengthens the §1202(c)(5) "link" theory.** `grip-1202-cmi-analysis.md` (Issue 1, defense) notes `PlatformID` is attackable as an "opaque, functional database key." This exhibit shows the pipeline **also removes `HelpURL` — a literal `https://gse.tools/sequences/<id>` URL**, i.e. a human-readable **"link to [author/owner] information"** squarely within §1202(c)(5). That is harder to dismiss as a mere routing token than the opaque ID, and it removes it **together with** GSE's integrity `Checksum`. The claimant's CMI characterization is meaningfully stronger with `HelpURL` + `Checksum` in the removed set, not just `PlatformID`.

**Advances recommendation #49(c).** The memo suggested "a captured GRIP export of your own sequence… shows a distributed copy with the identifier gone." A same-format before/after is captured here (on third-party content, because the rights holder's own sequences were refused). For the rights holder's *own* content, the decode-stage strip of `PlatformID`/`HelpURL`/`Checksum` is captured directly (`01_original_decoded.json` vs. the decode API response).

**The retained author name still cuts against the strip narrative (defense).** Consistent with the memo: `Author: ScaryLarryGames` survives both decode and convert. The claim is "the *source linkage and integrity signature* are removed," not "all attribution is removed."

**Reproduction angle is modest.** Finding 1's plaintext reproduction is user-initiated input to a decoder; it is not the tool sourcing or publishing the works.

## Honest limits of this exhibit
- No GRIP-format copy of the **rights holder's own** sequence with CMI removed was produced — the converter refused those sequences. Finding 3's before/after is third-party content.
- This exhibit does **not** claim LazyGrip hosts or redistributes the rights holder's sequences (that angle remains disproven and excluded).
- Operator identity ("Slowdog"/"Beard3d_Gamer" ↔ GRIP-EMS project ownership) is asserted from site attribution and should be confirmed by counsel.

## Files (in `evidence/lazygrip-webtool/`)
| File | Contents |
|---|---|
| `00_original_gse_string.txt` | Rights holder's original `!GSE3!` export (input) |
| `01_original_decoded.json` | Faithful decode — shows PlatformID/HelpURL/Checksum present |
| `02_thirdparty_BEFORE_gse.json` | Third-party GSE input, decoded (CMI present) |
| `03_thirdparty_AFTER_grip.json` | Same after Convert-to-GRIP (CMI stripped) |
| `04_thirdparty_grip_output_string.txt` | The `!GRIP1!` string LazyGrip produced |
| `screenshots/decode-export-SLG-DK-BLD-macros.png` | *(to add)* Decode Export showing rights holder's macros in plaintext |
| `screenshots/convert-to-grip-refusal-SLG.png` | *(to add)* Convert to GRIP refusing rights holder's collection by name |
