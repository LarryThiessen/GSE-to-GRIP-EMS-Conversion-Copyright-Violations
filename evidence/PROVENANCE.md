# Provenance — the GRIP-EMS release archives

Why three `.zip` files sit in an evidence repo, where they came from, and how a third party can check them.

## What they are

Unmodified GRIP-EMS release packages as distributed by CurseForge, retained because **every code citation in the exhibits points into them**. GRIP-EMS is not published on any public source host, so without these archives no file:line claim in this package can be verified by a reader.

| Archive | CurseForge file ID | CF upload date | Size | SHA-256 |
|---|---|---|---|---|
| `GRIP-EMS-v1.0.4.zip` | `7791035` | 2026-03-21 | 343,881 B | `c3f9677d27fe89c79cbd94a93abaaade47f6291a133afd94932a86285a584cbe` |
| `GRIP-EMS-v1.9.1.zip` | `7918661` | 2026-04-12 | 946,584 B | `4fa4269a89c46c61fbd3f06bfccee21a1b6ca3df1e3f5a1604114ea153cb7602` |
| `GRIP-EMS-v2.3.5.zip` | `8364957` | 2026-07-03 | 2,652,665 B | `b50ca92e643024fdef84477b325ba0cfaa1056967a077183634d1a8218bd8d2a` |

Hashes are also in `SHA256SUMS.txt`. Source project: CurseForge project **1489414**, `grip-enhanced-macro-sequencer`, author `sirsataana`.

- **v1.0.4** — first release in the scan; establishes the GSE-import path existed from the beginning.
- **v1.9.1** — mid-history control.
- **v2.3.5** — the version the exhibits cite as operative.

## Capture

- Downloaded from CurseForge's own file endpoints on **2026-07-12** (file timestamps 21:23 local) and committed the same day in `8332cc4`. The archives have not been opened, repacked, or altered since — the hashes above are the bytes as received.
- All three returned **HTTP 200** during the 2026-07-12 scan that produced `data/version_scan_raw.csv`, which records the file ID and result for all 64 releases.
- Captured by Larry A. Thiessen ("ScaryLarryGames").

## Why the archives are here, and why that is not a problem

**The releases remain public on CurseForge.** These copies are not a substitute for an unavailable original — anyone can still download the same files from the same project. That is a *feature* of this evidence, not a gap: a third party can re-download, hash, and confirm byte-identity with what is in this directory. Few evidence exhibits are that easy to check.

**What is not available is the source.** Per the rights holder, the GRIP-EMS author's GitHub repositories are **private**, and CurseForge distributes packaged builds only. So there is no public source tree to read or diff — the only way to examine GRIP's Lua, and therefore the only way to check a single `FILE:LINE` citation in the exhibits, is to obtain a release package and unpack it. That is precisely what these three archives are, pinned to fixed hashes so the citations always resolve against the same bytes even if a future release renumbers lines.

Keep these apart:

- **Verifiable by anyone:** that file IDs `7791035` / `7918661` / `8364957` resolve on CurseForge, that their bytes hash to the values above, and that `data/version_scan_raw.csv` records all three returning HTTP 200 on 2026-07-12.
- **On the rights holder's account:** that the author's GitHub repositories are private. Checkable, but not evidenced in this package.
- **Not claimed at all:** any motive for the repositories being private. This package does not allege one, and nothing here should be read as establishing it.

## How to verify these are genuine

1. `sha256sum -c SHA256SUMS.txt` against the archives in this directory.
2. **Re-download the same files from CurseForge** (project 1489414, the file IDs above), hash them, and compare. The values must match exactly — this is the check that matters, and it is available to anyone.
3. `data/version_scan_raw.csv` records the file ID and HTTP result for all 64 releases as fetched on 2026-07-12, if the comparison needs a wider baseline.
4. Any archive that fails step 1 or 2 should be treated as unreliable, not argued around.

## Scope note

These are the author's own published release packages, retained unmodified for evidentiary comparison and cited for the purpose of criticism and analysis. They are not offered as a download of the addon, and no derivative or modified build is distributed here.
