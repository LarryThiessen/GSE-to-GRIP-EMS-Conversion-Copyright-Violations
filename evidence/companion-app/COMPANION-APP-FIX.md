# GSE Companion — the one residual item in 0.4.22, and where it stands in 0.4.26

> ## Status in 0.4.26: scoped down, **not** removed — verified 2026-07-29
>
> The body of this document analyses **0.4.22**, the build the discloser captured. Re-checked against **0.4.26** (shipped `app.asar.original`, SHA-256 `c5e569a768acf03bfbe7fe8aa9a9d6a9c4a52f534fa913cc374f90534a57ac21`) and the current source:
>
> | Recommendation below | Status in 0.4.26 |
> |---|---|
> | 1. Sign every request (ed25519) | **Not done.** Gated on an authenticated session + freshly-refreshed bearer token instead of a per-request signature. |
> | 2. Make it opt-in | **Per the author, done:** all diagnostic uploads are now tied to a user-initiated request (2026-07-29). Client-side in 0.4.26 a `requestFiles` flag raises a user-visible notification, but the handler will still service a server-sent `kinds` request — so this is an operational/server-side assurance, or a change later than 0.4.26. State it as the operator's assurance, not as something the shipped client enforces. |
> | 3. Scope it down | **Largely done.** `Ho()` runs `n.delete("errorlogs")` before gathering, making the BugGrabber/BugSack reader `Co()` unreachable from a server request; `settings` is sent with `accessToken`/`userSession` deleted; the always-on portion is a GSE-only mandatory gather (`Po()`). |
>
> **Do not describe this path publicly as removed.** The capability the video showcased is gated off and the arbitrary-read concern is materially reduced, but the endpoint exists and item 1 is still open.
>
> **Anchor:** clean installer `GSE Companion Setup 0.4.26.exe` SHA-256 `c720ec821818fa2b58a4e50d71dbbd0c06c81c01ec573b5e2a4505554d0780d7` → `resources/app.asar` SHA-256 `c5e569a768acf03bfbe7fe8aa9a9d6a9c4a52f534fa913cc374f90534a57ac21` (6,210,073 bytes). The three statuses above were read from those shipped bytes.
>
> **Also true, and worth saying first:** the error-log reader is still *present* in the binary — only unreachable, because the `errorlogs` kind is dropped before any gather runs. A strings scan will find it. Describe it as unreachable, never as deleted.

**Why it is kept:** the discloser's public claims are about 0.4.22, so answering them requires an accurate record of what 0.4.22 contained — including the one item that was a fair criticism of that build. Deleting the record would look like concealment; dating it is stronger.

> Analyzed against the shipped **GSE Companion 0.4.22** build (`app.asar` → `out/main/index.js`, 137,312 bytes; SHA-256 `27716e71…4cd6e1`, which matches the discloser's own `hashes.txt`). Line numbers below are into that built `index.js` — map them to your source. **Confirm each against your real source before shipping.** See `COMPANION-FORENSIC-FINDINGS.md` §3 for the full context.

---

## TL;DR

In **0.4.22** there was **one unsigned code path** that could gather files from the WoW folder and upload them, not protected by the same ed25519 signature gate the destructive/directive path already used. **No evidence it was ever misused.** In 0.4.26 it is **substantially scoped down but not removed** — see the status box above. The analysis below is the dated record of 0.4.22, the build the disclosure is actually about.

---

## The issue as it stood in 0.4.22 — the unsigned diagnostic upload

- An SSE message `companion:request` (`index.js` ~1704) triggers `zo()` (~1455), which:
  - gathers files **by kind** — including **BugGrabber/BugSack** error logs via the `Ao` regex `/^!?Bug(Grabber|Sack)\.lua$/i` (~911 / ~997), **and**
  - reads **server-specified paths** under `Interface\AddOns` and `WTF`,
  - then **POSTs their contents** to `/diagnostic/upload` (~1479).
- **This path is not ed25519-signed and not `enforce`-gated.** Compare: your *directive* engine (`qo()` verify ~1055 → `Jo()`/`Po()` run ~1514) only runs a plan if it is **signed, unexpired, persona-matched, and WoW is closed**. The diagnostic upload has none of those guards.
- Practical reach: it can read the server-named files under AddOns/WTF and the BugGrabber/BugSack logs, and send them up — on an unsigned server request.

**Why this is the fair point:** everything else the critics raised was refuted (the delete never armed — `enforce:false` on all three of their own captures — and is removed) or misframed (the "paywall," the "bans"). This one is real: a path that *can* pull a user's files without a signature or an explicit opt-in. **In 0.4.22, as analysed here.** For what has and has not changed since, see the status box at the top — two of the three recommendations below are now largely or partly met.

---

## The fix — three changes

1. **Sign it.** Require the same `v2:` ed25519 signature on every `companion:request` / gather / upload that the directive path already enforces via `qo()`. An unsigned request should be rejected before `zo()` runs. (One gate, reused — you already have the verifier.)
2. **Make it opt-in.** Tie any file gather/upload to a **user-initiated bug report** (you already have `As()` / `report:submit` ~2949/2982, which honors `includeModList`). No silent/background collection: the user clicks "send report," sees what's attached, and confirms.
3. **Scope it down.** Restrict reads to **GSE's own files** (and only what a bug report needs), not arbitrary server-specified paths under AddOns/WTF. Publish, in plain language, exactly what a report attaches.

---

## How to verify after the change

1. Rebuild; extract `app.asar` → `out/main/index.js`.
2. Confirm the `companion:request` → `zo()` → `/diagnostic/upload` path now **rejects an unsigned request** (same failure as an unsigned directive plan).
3. Confirm no gather/upload fires without a user-initiated report + confirmation.
4. Confirm reads are limited to GSE's own files.
5. Bump the version and note the hardening in the changelog — then the public answer is "it's signed, opt-in, and scoped; here's the build hash," not a denial.

---

*Not legal advice. Prepared from a read of the shipped binary; you are the author and hold the real source — verify before shipping. Pairs with `RESPONSE-brief-for-Tim.html` (§4, the same point) and `COMPANION-FORENSIC-FINDINGS.md` (§3, full detail).*
