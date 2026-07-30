# Claim Screenshots — Reading Order & Index

The actual slides/screenshots from Sataana's `gse-companion-disclosure` and the **TheKephas** video, plus Tim's Discord reply and the GSE.Tools collections page — recovered at **full resolution**. **Read top to bottom.** Each is paired with what it claims and where it's answered in [`../COMPANION-FORENSIC-FINDINGS.md`](../COMPANION-FORENSIC-FINDINGS.md).

| # | File | What it shows (their side) | Our answer |
|---|---|---|---|
| 01 | `01_kephas-video-page.png` | The video itself — TheKephas, "We Need to Talk About the GSE Addon Community" (context). | — |
| 02 | `02_tim-reply-canary.png` | Tim's Discord reply: *"trolls… stealing parts of GSE… put GSE through AI… I detect someone is tampering so I put in a **canary**."* | Tim's own framing. The "delete" code was a dormant tripwire. → Findings §1 |
| 03 | `03_claim_gsetools-faq-patreon-paywall.png` | GSE.Tools FAQ: creators can link Patreon to gate premium sequences. **(the "paywall / breaks the EULA" claim)** | Misframed — the **addon is free**; GSE.Tools takes no money; this is a *creator's own* optional Patreon. → Verdict row 3 |
| 04 | `04_rebuttal_gsetools-collections-public-sets.png` | GSE.Tools collections: SLG class **sets marked PUBLIC** (free). | **Rebuts** slide 03 — the sets are free; only some specs are subscriber. |
| 05 | `05_claim_supporting-gse-graphic.png` | Community graphic: *"if GRIP usage is detected, Discord access may be revoked."* **(the "surveils & bans" claim)** | Human moderation of a documented scraping group — not automated surveillance. → Verdict row 4 |
| 06 | `06_claim_disclosure-text-protect-integrity.png` | Disclosure text: *"the GSE author took steps to protect… users' sequence files… other tools… were corrupting their file."* | The stated justification; context for the clawback/canary. |
| 07 | `07_claim_code_base64-decode-grip-strings.png` | The GRIP target strings are **base64-encoded** (`GRIP-EMS.lua`, `GRIP_EMS_CHAR`, `provenanceSource`, `gse-legacy`). | Confirms obfuscation. These lived in **0.4.12–0.4.14**; **absent from the current 0.4.22** (verified). → §1 |
| 08 | `08_claim_code_detect-grip-flag-cleanup.png` | Detect GRIP → set `restricted` → `runAccountCleanup`, **gated by `restricted && enforce`.** | **The trigger.** `enforce` was `false` on every date the discloser captured it → **never ran**. → §1 |
| 09 | `09_claim_code_delete-gse-legacy-from-grip.png` | The delete loop: removes only sequences tagged `gse-legacy` / matching GSE names from GRIP's file, then rewrites it. | Targets **only GSE's own scraped content** — and never executed (see 08). → §2 |
| 10 | `10_claim_code_signed-directive-engine.png` | The current (0.4.22) **signed** engine: verify → run only if signed & WoW closed → ops `read/deleteKeys/setKey/write`. | Real current capability, but **signature-gated**. The *unsigned* diagnostic upload is the one item to fix. → §3 |

---

**The single most important pairing:** slide **08** shows the delete only fires when `enforce` is true. The discloser's **own** captures — [`../discloser-own-evidence/live_access_policy_2026-06-20.json` / `-06-21.json` / `-07-09.json`](../discloser-own-evidence/) — all read **`"enforce": false`**. Claim (08 + 09) **+** his own proof (`enforce` off, three dates) **= it never ran.** That is the whole rebuttal in one line.

> Slides 07–10 are cleaned-up / de-minified renderings by the discloser (readable variable names). The *logic* is corroborated against the real bytes (see the Findings doc); treat the exact syntax as his rendering, not raw source.
