# LazyGrip.net — Operator, Hosting, and Converter Provenance

**Compiled:** 2026-08-01
**Method:** public DNS, RDAP/WHOIS, live HTTP response headers, Internet Archive snapshots, and the site's own **public source repository**. No account was used, no authenticated endpoint was accessed, and no automated crawl was run — individual requests only.

**Why this exhibit exists.** The complaint and its exhibits describe conversion behaviour observed from the outside: a `!GSE3!` string goes in, a `!GRIP1!` string comes out, and certain owner-identifying fields did or did not survive. That behaviour can now be sourced directly, because the site is built from a **public MIT-licensed GitHub repository** with full commit history. This exhibit records who operates the service, where it runs, and what the converter's own version control says about when its handling of owner-identifying metadata changed and why.

**Standard of proof used here.** Every factual line below is either a registry record, a live HTTP header, an archived page, or a commit object in a public repository — each with a hash, a SHA, or a URL. Where a conclusion would require inferring motive, the exhibit states the dated sequence and stops. Two findings in §6 are direct written admissions by the parties themselves and are quoted verbatim rather than characterised.

---

## 1. Summary of findings

| # | Finding | Basis |
|---|---|---|
| 1 | The GRIP-EMS addon author (GitHub `JesperLive` / **Jesper Driessen**) holds commit access to, and contributes code to, the LazyGrip.net website repository | 32+ commits, merged PRs, public commit metadata |
| 2 | The site publicly denied that affiliation until **2026-07-30**, when the developer himself removed the denial, writing that it **"is not accurate"** | Commit `234fcd2` message, verbatim |
| 3 | The converter **did not** carry `PlatformID`, `HelpURL`, `Checksum` or `GSEVersion` through GSE→GRIP conversion until **2026-07-30 15:53:54 UTC** | Commit `8d541bc` diff — the fields are *additions* |
| 4 | Until **2026-07-30**, LazyGrip.net asserted a site-wide **CC BY-NC-SA 4.0 licence over all user-submitted sequences** — "free to share and adapt" | Archived footer, 2026-07-09 |
| 5 | That CC licence claim was removed on 2026-07-30 with the stated reason that **"a submitter cannot grant a Creative Commons licence over a sequence someone else wrote and reserved rights in"** | Commit `234fcd2` message, verbatim |
| 6 | The site had **no copyright or DMCA policy of any kind** until 2026-07-30/31 | Archived ToS 2026-07-09 contains zero occurrences of "copyright" |
| 7 | Conversion runs **server-side on the operator's own infrastructure** (Vercel), not in the user's browser | No codec in client bundle; `POST /api/workshop/convert` |
| 8 | Domain registrant is masked behind a WHOIS privacy service; operator identity is established from the public source repository instead | RDAP + repo commit metadata |

Findings 2, 3, 4 and 5 all fall in a **48-hour window beginning the day the rights holder's evidence package was made public**. The exhibit records the timeline in §7 and draws no inference from it beyond the dates themselves.

---

## 2. Domain, hosting and infrastructure

### 2.1 Domain registration (RDAP, Verisign registry + Namecheap registrar, retrieved 2026-08-01)

| Field | Value |
|---|---|
| Domain | `LAZYGRIP.NET` |
| Registry handle | `3095025417_DOMAIN_NET-VRSN` |
| **Registered** | **2026-05-03 16:02:34 UTC** |
| Expires | 2027-05-03 16:02:34 UTC |
| Last changed | 2026-05-03 16:02:39 UTC |
| Status | `client transfer prohibited` |
| Registrar | **NameCheap, Inc.** (IANA ID 1068), abuse: `abuse@namecheap.com` |
| Nameservers | `dns1.registrar-servers.com`, `dns2.registrar-servers.com` |
| **Registrant** | **"Privacy service provided by Withheld for Privacy ehf"**, Kalkofnsvegur 2, Reykjavik, Capital Region 101, Iceland |
| Registrant contact | `6daac438798a4fbe824e629f6f4bc9d2.protect@withheldforprivacy.com`, tel `+354.4212434` |
| Technical contact | identical to registrant (same privacy service) |

The true registrant is not disclosed by WHOIS. This is an ordinary privacy service and no adverse inference is drawn from its use. Operator identity is established independently in §3.

Note the date alignment: the domain was registered **2026-05-03**, and the original Privacy Policy and Terms of Service both carry "Last updated: **May 3, 2026**."

### 2.2 Web hosting

Live response headers, `GET https://lazygrip.net/`, 2026-08-01 14:34 UTC:

```
HTTP/1.1 200 OK
Server: Vercel
X-Vercel-Cache: HIT
X-Vercel-Id: iad1::rjwg6-1785594874482-9bad59fc821b
X-Nextjs-Prerender: 1
X-Matched-Path: /
Strict-Transport-Security: max-age=63072000
```

- **A record:** `216.198.79.1`
- **IP RDAP (ARIN):** network `VERCEL-05`, handle `NET-216-198-79-0-1`, range `216.198.79.0 – 216.198.79.255`, registrant **Vercel, Inc.** (entity handle `ZEITI`)
- **Stack:** Next.js (App Router) deployed on Vercel, edge region `iad1`
- **Database and authentication:** Supabase, project `csldntgdalzlwxozlmgv.supabase.co` (referenced in the site's own client bundle and stated on the Privacy Policy: *"LazyGrip.net runs on Supabase for the database and authentication, and Vercel for hosting."*)
- **Mail:** ProtonMail — `MX 10 mail.protonmail.ch`, `MX 20 mailsec.protonmail.ch`; TXT `protonmail-verification=ebe701636f991298892c62e6332f74ceef27f6b8`; SPF `v=spf1 include:_spf.protonmail.ch include:spf.efwd.registrar-servers.com ~all`

### 2.3 The forum is separate infrastructure

`forum.lazygrip.net` → `146.190.208.35`

- **IP RDAP:** `DO-13`, `146.190.0.0 – 146.190.255.255`, registrant **DigitalOcean, LLC**
- Headers identify **Discourse** behind nginx (`X-Discourse-Route: list/latest`, `X-Discourse-Crawler-View: true`), i.e. self-hosted on a DigitalOcean droplet — not Vercel.

So the operator runs two distinct services: the Next.js site on Vercel and a self-hosted Discourse forum on DigitalOcean. Announced on the site as *"NEW: The GRIP-EMS Community Forum is live."*

### 2.4 Correspondence address

A single contact address appears throughout the site: **`admin@lazygrip.net`** — used for account deletion, privacy requests, general contact, informal takedown, and (as of 2026-07-31) as the designated DMCA agent.

---

## 3. Who operates and builds the site

### 3.1 The site's source code is public

**Repository: `https://github.com/lazygrip/lazygrip-gg`**

| Field | Value |
|---|---|
| Organisation `lazygrip` created | 2026-04-30 03:18:11 UTC |
| Repository created | 2026-04-30 03:21:13 UTC |
| Visibility | **Public**, not a fork |
| Licence | **MIT** |
| Language | TypeScript |
| Description | "Community GRIP-EMS sequences for World of Warcraft" |
| Homepage field | `https://lazygrip-gg.vercel.app` |
| Default branch | `main` |
| Last push (at compile time) | 2026-07-31 18:01:34 UTC |
| Tree size | 197 files |

This is the deployed application: it contains `vercel.json`, the Supabase migrations, and the exact API routes the live site serves (`/api/workshop/convert`, `/api/workshop/decode`), matching the live `X-Matched-Path` headers.

### 3.2 Contributors

From the public contributor list and commit metadata:

| GitHub account | Commits | Git author identity as recorded publicly |
|---|---|---|
| **`slowdog-dev`** | 332 | name `slowdog-dev`, email `edosta@proton.me` |
| **`JesperLive`** | 32 | name `JesperLive` and, on 7 commits, **`Jesper Driessen`**; email `150523742+JesperLive@users.noreply.github.com` |
| `github-actions[bot]` | 24 | CI |

**`slowdog-dev`** — GitHub account created **2026-04-30 03:13:08 UTC**, five minutes before the `lazygrip` organisation. Zero public repositories of its own. This matches the credit printed on the site's own Workshop page: *"integrated on LazyGrip by **Slowdog**."* The git author email `edosta@proton.me` is a ProtonMail address, consistent with the domain's ProtonMail MX records. This account is the site operator: `.github/CODEOWNERS` requires **`@slowdog-dev`** approval to merge any change to the database migrations, SQL, Supabase auth config, `.env.example`, `vercel.json`, `next.config.js`, or `.github/` itself — with the comment *"so this protection can't be quietly edited."*

**`JesperLive`** — GitHub profile name **Jesper Driessen**, location as stated on the profile *"Kirkby in Ashfield, Notts, England, UK, GB"*, account created 2023-11-11, 7 public repositories including **`JesperLive/grip-ems-guide`** ("Interactive guide for GRIP – Enhanced Macro Sequencer (WoW addon)") and **`JesperLive/GRIP-EMS-PluginAPI`** ("Developer documentation for the GRIP – Enhanced Macro Sequencer plugin API"). The CurseForge project complained of in the main complaint is authored by **Sataana (MrSataana / JesperLive)**. He does not merely contribute: the commit log shows him merging pull requests into `main` under the name *Jesper Driessen* (e.g. `5ea6e12`, `e539ab5`, `67bfba8`, `fcda910`, `471b55f`, `0747150`, `2821a0d`).

**Beard3d_Gamer** — the Workshop tools are credited on the site itself. From the deployed client bundle, `/workshop`:

> **"Tools by Beard3d_Gamer"**
> "Browser-based export tools and in-game addons built for the GRIP-EMS community, integrated on LazyGrip by Slowdog."
> "Built by [**Beard3d_Gamer**](https://ko-fi.com/beard3d_gamer)"

The Ko-fi link is a donation page. *(Per the correction already recorded in `evidence/discord/captures.md`: "Beard3d_Gamer" and the Discord account "BeardBd_Gamer" are treated as the same person only where separately sourced; no identity claim beyond the site's own credit is made here.)*

### 3.3 The affiliation denial, and its withdrawal

**Until 2026-07-30**, the site's Terms of Service and site-wide footer stated:

> "LazyGrip.net has no affiliation with Blizzard Entertainment **or the GRIP-EMS addon developer**."
> — archived `/tos`, 2026-07-09, "Disclaimers" section
>
> "LazyGrip.net — Not affiliated with Blizzard Entertainment or the GRIP-EMS addon."
> — archived site-wide footer, 2026-07-09

**On 2026-07-30 12:08:43 UTC**, commit `234fcd24d628d6a2955fcd3f7a30f0d9f5419767`, authored by **JesperLive**, changed that text across the footer, `/about`, `/tos` and `/faq`. The commit message states the reason in the developer's own words:

> **"Ownership wording. The disclaimer said the site is not affiliated with the GRIP-EMS developer. That is not accurate, because the developer holds commit access on this repository and contributes code.** The footer, /about, /tos and /faq now say the site is independently owned and operated and is not an official GRIP-EMS site, and the FAQ states the contributor relationship directly rather than denying it."

The replacement wording, live today:

> "LazyGrip.net is a community site, independently owned and operated. Not affiliated with or endorsed by Blizzard Entertainment, and not an official GRIP-EMS site."

Note what changed and what did not: the reference to Blizzard is retained; the denial of affiliation **with the GRIP-EMS developer** is gone, replaced by "not an official GRIP-EMS site" — which is a different statement.

**This is a written admission, by the addon developer, that the earlier public denial of affiliation between the addon and the conversion website was inaccurate.** It is quoted, not characterised.

---

## 4. Where the conversion actually runs

### 4.1 Server-side, on the operator's infrastructure

The converter is at `https://lazygrip.net/workshop/convert`. All twelve JavaScript chunks the page loads were retrieved and searched (926,398 bytes total):

| Marker | Occurrences in client bundle |
|---|---|
| `pako` / `inflateRaw` / `deflateRaw` | **0** |
| `cbor` / `CBOR` | **0** |
| `/api/workshop/convert` | present |
| `/api/workshop/decode` | present |

The container format used by both GSE and GRIP is CBOR → raw DEFLATE → Base64. **None of that codec is in the browser.** The page collects the pasted string and POSTs it to the site's own API route. Conversion — decode, transform, re-encode — happens on **the operator's server**, on Vercel, under their control.

Confirmed live: `GET https://lazygrip.net/api/workshop/decode` → `405 Method Not Allowed`, `Server: Vercel`, `X-Matched-Path: /api/workshop/decode`, `X-Vercel-Id: iad1::iad1::l2qb2-…` (a Vercel serverless function, POST-only).

### 4.2 It does not fetch from GitHub at runtime

The client bundle references no external host other than the site's own Supabase project and Vercel's own feedback script. The GitHub URLs present in the bundle are third-party library boilerplate (`core-js` licence headers, a Supabase discussion link in a warning string) and are not fetched. **GitHub is the source of the deployed code, not a runtime dependency.** Vercel builds and deploys from `lazygrip/lazygrip-gg`; the running converter contains that code compiled in.

### 4.3 The route

`src/app/api/workshop/convert/route.ts` (as at 2026-08-01, archived in `evidence/lazygrip-site/`):

```ts
export async function POST(req: NextRequest) {
  const ip = getClientIp(req)
  if (!checkRateLimit(`workshop-convert:${ip}`, { limit: 30, windowMs: 60_000 })) {
    return NextResponse.json({ error: 'Too many requests…' }, { status: 429 })
  }
  let body: { code?: string }
  try { body = await req.json() } catch { … }
  const { code } = body
  if (!code || typeof code !== 'string') …
  if (!/^!GSE3!/i.test(code.trim())) {
    return NextResponse.json({ error: 'Convert expects a !GSE3! export code.' }, { status: 422 })
  }
  const result = convertGSEExportToGRIP(code.trim())
  return NextResponse.json(result)
}
```

There is **no authorship check, no licence check, and no consent check** on this path. The only gate is an IP rate limit — and that rate limit was itself only added on **2026-07-31 17:40:23 UTC** (commit `d3cd7f5`, *"Add IP rate limiting to public Workshop decode/convert routes"*). Before that date the route had no gate at all.

The transformation itself is `src/lib/workshop/gseToGrip.ts` (archived); supporting modules include `gseDecoder.ts`, `gripEnvelope.ts`, `emsDecoder.ts`, `emsEncoder.ts`, `cborEncode.ts`, `serialization.ts`, `forgeImport.ts` and `authorLock.ts`.

### 4.4 `authorLock.ts` — the site has an author-lock mechanism, and it is HMAC-signed

`src/lib/workshop/authorLock.ts` implements a server-side author lock: an HMAC-SHA256 token over `{lockedAuthor, originalAuthor, originalAuthorRealm, exporterName, exporterRealm, sequenceName}`, signed with a server secret (`LAZYGRIP_AUTHOR_LOCK_SECRET`; the module refuses to load without it). `enforceAuthorLock()` verifies the token per sequence and, if no token verifies, calls `clearAuthorLock()` which **deletes** `lockedAuthor`, `originalAuthor`, `originalAuthorRealm`, `author`, `exporterName` and `exporterRealm` from the export metadata.

Recorded here as a factual description of the mechanism. It demonstrates that the operator is capable of binding an author identity to a sequence cryptographically and enforcing it server-side — the same class of control GSE.Tools applies via `PlatformID`. Whether it is applied to GSE-sourced content, and on what terms, is not determined by this exhibit.

---

## 5. The converter's handling of owner-identifying metadata — dated from its own history

This section resolves an open item in the package. Testing on **2026-07-12** found that conversion stripped `PlatformID`, `HelpURL` and `Checksum`. Re-testing on **2026-08-01** found all three preserved. The repository dates the change precisely.

### 5.1 The commit that added them

**`8d541bcbf68def23c2cf4308336e4bb59391176b`** — author **`slowdog-dev <edosta@proton.me>`**, **2026-07-30 15:53:54 UTC**

> `fix(workshop): carry HelpURL, PlatformID, Checksum, and GSEVersion through GSE conversion`

Commit message, verbatim:

> "Sataana's commit from earlier tonight (6dea7e0) fixed the collection helplink field but that field is a Discord invite link, it's not the same thing as HelpURL, **which is the actual gse.tools owner listing link**. I checked the real GSE export JSON and GSE stores both fields separately, Helplink and HelpURL, so his fix passes through the wrong one and **HelpURL was still getting dropped**.
>
> This adds HelpURL, PlatformID, Checksum, and GSEVersion alongside the existing helplink field… **These now flow through the decoder into the GRIP export payload itself, so they're baked into the exported string**, not just shown somewhere in the UI. The decode API route also returns them now instead of dropping them silently."

The diff proves the prior state, because every one of the fields is an **addition**:

`src/lib/workshop/gseDecoder.ts` — before this commit the decoder built its export metadata as:

```ts
        author: metaData.Author || metaData.author || "",
        description: metaData.Help || metaData.help || "",
        collectionName: "",
-       url: ""
```

and after:

```ts
+       url: "",
+       helplink: metaData.Helplink || metaData.helplink || "",
+       helpUrl:  metaData.HelpURL  || metaData.helpUrl  || "",
+       platformId: metaData.PlatformID || metaData.platformId || "",
+       checksum:   metaData.Checksum   || metaData.checksum   || "",
+       gseVersion: metaData.GSEVersion || metaData.gseVersion || null
```

`src/lib/workshop/gseToGrip.ts` — the per-sequence payload, before:

```ts
   return {
     icon: DEFAULT_ICON,
-    author: exportMeta.author || "",
     description: sequence.description || exportMeta.description || "",
     help: String(sequence.help || "").trim(),
```

and after:

```ts
+    author: sequenceMeta.Author || sequenceMeta.author || exportMeta.author || "",
     description: …,
     help: …,
+    helplink:   String(sequenceMeta.Helplink   || … ).trim(),
+    helpUrl:    String(sequenceMeta.HelpURL    || … ).trim(),
+    platformId: String(sequenceMeta.PlatformID || … ).trim(),
+    checksum:   String(sequenceMeta.Checksum   || … ).trim(),
+    gseVersion: sequenceMeta.GSEVersion || … || null,
```

**Conclusion — verified.** Before 2026-07-30 15:53:54 UTC, the converter's output payload contained no `platformId`, no `helpUrl`, no `checksum` and no `gseVersion` field at all. Those fields were introduced on that date. The observation recorded on 2026-07-12 (stripped) and the observation recorded on 2026-08-01 (preserved) are both correct, and the transition is dated to the second by the operator's own version control.

The commit message also confirms, in the operator's own words, the significance of the field: `HelpURL` is *"the actual gse.tools owner listing link."*

### 5.2 The immediately preceding commit

**`6dea7e054e5ca9882cd99790835e0a0b0b961f76`** — author **JesperLive**, **2026-07-30 02:44:36 UTC**
> `fix(workshop): carry Helplink through GSE conversion and stop collapsing multi-sequence authors`

Merged as PR #25 from branch **`JesperLive/fix/workshop-attribution-passthrough`**. Thirteen hours before `8d541bc`, and the branch name states its purpose: attribution pass-through.

### 5.3 The follow-up commit

**`baeb88d5f07da5a5ded454e71dded5aa68fb304f`** — author **JesperLive**, **2026-07-31 00:35:06 UTC**
> `workshop: carry GSE source metadata through conversion and show origin`

Merged as PR #27 from `JesperLive/feat/workshop-gse-origin-label`. Message, verbatim in relevant part:

> "helpUrl, platformId, checksum and gseVersion are emitted only when the source had a value. They were previously written on every converted sequence, so a payload carried four empty keys whether or not there was anything to put in them…
>
> The converter stamps provenanceSource "gse-legacy" on sequences it produces…
>
> **No gse.tools link and no Discord link is rendered anywhere. helpUrl, platformId and checksum are carried in the payload but are not shown in the UI.**"

That final sentence is material. As at 2026-07-31, the fields are **carried in the exported payload but deliberately not displayed**. This is consistent with the finding already recorded elsewhere in this package: GRIP the addon references `platformId`, `helpUrl` and `gseVersion` **zero times** across its Lua source in both v2.3.5 and v2.3.16, and reads GSE's `Checksum` once, at `UI/ImportPreview.lua:745`, marked *"informational"*, without storing it. The website now passes the owner-identifying fields through; nothing downstream reads them, and nothing shows them to the user.

---

## 6. Content licensing — what the site claimed, and what it withdrew

### 6.1 The CC BY-NC-SA claim (in force until 2026-07-30)

The site-wide footer, present on every page — captured on the archived homepage and the archived `/tos` of **2026-07-09**:

> **"Community content on LazyGrip.net is licensed under [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/). Free to share and adapt with attribution, for non-commercial use only."**

The Creative Commons URL was a live hyperlink. The accompanying Terms of Service, "Your Content" section, as at 2026-07-09:

> "You own what you post. By posting it here you are giving us a license to store, display, and distribute it to other users. That license ends when you delete the content or close your account, after any backup retention period clears."

**There was no authorship warranty.** Nothing required an uploader to confirm they wrote the sequence or had permission to share it. And over everything uploaded, the site asserted a **CC BY-NC-SA 4.0 licence — a licence that expressly permits third parties to share and to adapt.**

For an All-Rights-Reserved work uploaded without its author's permission, that is a purported sublicence the site had no right to grant, extended to the world.

### 6.2 The withdrawal, and the stated reason

Commit **`234fcd24d628d6a2955fcd3f7a30f0d9f5419767`**, author **JesperLive**, **2026-07-30 12:08:43 UTC**, modified `src/components/layout/Footer.tsx` (+5/−7) and `src/app/tos/page.tsx` (+8/−3). The footer patch:

```diff
-          Community content on LazyGrip.net is licensed under{' '}
+          Sequences stay the property of the people who wrote them. By posting you confirm you wrote
+          the sequence or have the author&apos;s permission. If your work is here without permission, email{' '}
           <a
-            href="https://creativecommons.org/licenses/by-nc-sa/4.0/"
-            target="_blank"
-            rel="noopener noreferrer"
+            href="mailto:admin@lazygrip.net"
           >
-            CC BY-NC-SA 4.0
+            admin@lazygrip.net
           </a>
-          . Free to share and adapt with attribution, for non-commercial use only.
+          {' '}and it comes down.
```

The ToS patch added the authorship warranty that had never existed:

```diff
-          <p>You own what you post. By posting it here you are giving us a license to store, display,
-             and distribute it to other users. …</p>
+          <p>You own what you post and you keep owning it. By posting you confirm that you wrote the
+             sequence, or that its author has given you permission to share it. Posting someone
+             else's sequence without permission is not allowed and we will remove it. …</p>
```

and introduced a "Reporting Your Own Work" section pointing at `admin@lazygrip.net`.

The commit message states the reason, verbatim:

> **"Content licensing. Removed the CC BY-NC-SA 4.0 claim over user-submitted sequences. A submitter cannot grant a Creative Commons licence over a sequence someone else wrote and reserved rights in.** The footer now states that sequences remain the property of their authors, with a takedown contact, /tos gains an authorship warranty, and a new section gives authors a plain-language route to report their own work without needing a legal notice."

**This is a written acknowledgment by the GRIP-EMS addon developer that the site had been asserting a Creative Commons licence over sequences whose authors had reserved their rights, and that a submitter had no power to grant it.** It is quoted, not characterised. The rights holder's works are All Rights Reserved (SLG-Sequences Licence, clauses 2(a), 2(b), 2(d), 3, 4) and the works are 100% Private on GSE.Tools.

### 6.3 There was no copyright policy at all before this

The archived `/tos` of **2026-07-09** was searched in full for: `copyright`, `DMCA`, `designated agent`, `Copyright Office`, `counter-notice`. **All five return zero occurrences.** The document contained Agreement, Who Can Use the Site, Your Account, Acceptable Use, Content Standards, Your Content, Enforcement, Disclaimers, Limits on Liability, Termination, Changes, Contact — and no copyright provision of any kind. Liability was capped at **$50**.

### 6.4 The DMCA policy added 2026-07-31

Commit **`85e7e738bc3512d2c928a30ebd6f88bfad4e7a11`**, author **`slowdog-dev`**, **2026-07-31 01:17:23 UTC**:

> `Add DMCA notice-and-takedown policy to Terms of Service`

Message, verbatim in relevant part:

> "Replaces the 'Reporting Your Own Work' section on /tos with a full Copyright and DMCA section covering: Designated agent contact (admin@lazygrip.net), noted as covering both LazyGrip.net and the GRIP-EMS Community forum; Formal DMCA takedown notice requirements…; Counter-notice process…; Repeat infringer policy; Section 512(f) misrepresentation liability note…
>
> **Copyright Office agent registration is in progress but not yet filed, so the text currently says 'in the process of registering' rather than claiming the designation is filed.** Update that line once registration is confirmed."

The live text as at 2026-08-01 reads:

> "our designated agent for copyright notices is: LazyGrip.net DMCA Agent, Email: admin@lazygrip.net. This designation covers both LazyGrip.net and the GRIP-EMS Community forum. **We're in the process of registering this agent with the U.S. Copyright Office.**"

**Note for the complaint file.** Under 17 U.S.C. § 512(c)(2), the safe harbour for user-stored content is available only to a service provider that has **designated an agent with the Copyright Office** and made the information available on its site and to the Office. By the operator's own commit message, that registration **was not filed as at 2026-07-31**. Whether it has since been filed is **not verified** — the Copyright Office's public directory returned a redirect and was not successfully queried. This is recorded as a fact about the operator's own statement of its position, not as a legal conclusion.

### 6.5 Posting gates added 2026-07-31

- **`6c40530`** 2026-07-31 17:07:31 — *"Add posting requirements section to Terms of Service"*
- **`d3cd7f5`** 2026-07-31 17:40:23 — *"Add IP rate limiting to public Workshop decode/convert routes"*
- **`5a2d328`** 2026-07-31 18:01:32 — *"Sync posting verification gate to repo + bump next.js"*

The accompanying `SECURITY_AUDIT_2026-07-31.md` in the repository states the trigger:

> "an unverified Battle.net account (auth never completed, no confirmed email, no display name) published a low-effort, taunting sequence through the normal posting flow. That flow had no gate beyond 'are you signed in as yourself'…"

New database functions `is_verified_poster()` (display name set, auth completed, account older than 60 minutes) and `check_post_rate_limit()` (1 post/hour, 3/day for accounts under 7 days) were added. Recorded for completeness; the trigger described is not connected to the rights holder.

---

## 7. Timeline

All times UTC. Registry, archive and commit records; each row is independently checkable.

| Date/time | Event | Source |
|---|---|---|
| 2026-04-30 03:13:08 | GitHub account `slowdog-dev` created | GitHub API |
| 2026-04-30 03:18:11 | GitHub organisation `lazygrip` created | GitHub API |
| 2026-04-30 03:21:13 | Repository `lazygrip/lazygrip-gg` created | GitHub API |
| 2026-05-03 16:02:34 | Domain `lazygrip.net` registered via Namecheap, WHOIS privacy | RDAP |
| 2026-05-03 | Original Terms of Service and Privacy Policy published | archived `/tos` |
| 2026-07-09 13:49 | **Archived state:** footer asserts **CC BY-NC-SA 4.0** over all community content; ToS contains **no copyright or DMCA provision**; disclaimer states **"no affiliation with … the GRIP-EMS addon developer"** | Wayback `20260709134941` |
| **2026-07-12** | Rights-holder test: conversion **strips** `PlatformID`, `HelpURL`, `Checksum` | package exhibit |
| 2026-07-21 15:58 | `Rename workshop_new to workshop now that the old engine is gone` (JesperLive) | commit `05f466d` |
| **2026-07-29** | Rights holder's evidence package and operator statement made public | package record |
| 2026-07-29 20:38 – 22:27 | Nine commits by JesperLive merged | commits `00d9075` … `3969662` |
| **2026-07-30 02:44:36** | JesperLive — *carry Helplink through GSE conversion* (branch `fix/workshop-attribution-passthrough`) | commit `6dea7e0` |
| **2026-07-30 12:08:43** | JesperLive — **CC BY-NC-SA claim removed**; **affiliation denial withdrawn as "not accurate"**; authorship warranty added | commit `234fcd2` |
| **2026-07-30 15:53:54** | slowdog-dev — **`PlatformID`, `HelpURL`, `Checksum`, `GSEVersion` carried through conversion for the first time** | commit `8d541bc` |
| 2026-07-30 16:16:13 | Same change re-applied after merge | commit `561a458` |
| **2026-07-31 00:35:06** | JesperLive — fields emitted only when non-empty; *"carried in the payload but are not shown in the UI"* | commit `baeb88d` |
| **2026-07-31 01:17:23** | slowdog-dev — **DMCA notice-and-takedown policy added**; agent registration *"in progress but not yet filed"* | commit `85e7e73` |
| 2026-07-31 17:07:31 | Posting requirements added to ToS | commit `6c40530` |
| 2026-07-31 17:40:23 | IP rate limiting added to public convert/decode routes | commit `d3cd7f5` |
| 2026-07-31 18:01:32 | Posting verification gate synced | commit `5a2d328` |
| **2026-08-01** | Rights-holder re-test: conversion **preserves** `PlatformID`, `HelpURL`, `Checksum`, adds `provenanceSource: "gse-legacy"` | package exhibit |
| 2026-08-01 14:34 | This exhibit compiled; live pages captured and hashed | §8 |

**On causation.** Four material changes — the licence withdrawal, the affiliation-denial withdrawal, the metadata pass-through, and the DMCA policy — all fall within roughly 37 hours of each other, beginning the day after the rights holder's package was published. This exhibit asserts the dates and the actors' own stated reasons. It does not assert why. The reader may draw their own conclusion from the record.

### 5.4 None of this reaches the addon's own converter

The website is not the only conversion path, and the change above does not touch the other one.

GRIP ships an **in-game Migrate button**, tooltipped *"Import all sequences from another sequencer"*, implemented in `Import/LegacyMigrate.lua` — header dated **Updated: 2026-07-26**, present and current in the shipping v2.3.16 build. What it does, from that file:

```lua
function LM.IsSourceActive()                     -- :24
    return C_AddOns.IsAddOnLoaded("GSE")
end
…
    local lib = _G.GSE and _G.GSE.Library or nil  -- :96
    if lib and _G.GSE.EnsureClassLoaded then      -- :102-104
        pcall(_G.GSE.EnsureClassLoaded, classID)  -- force-load every class
…
    if _G.GSESequences then …                     -- :193-197  SavedVariables fallback
    if _G.GSEVariables … then                     -- :262
    if _G.GSEMacros … then                        -- :288
```

It detects GSE, force-decompresses every class of the user's library, and bulk-copies the sequences, variables and macros out of GSE's own in-memory tables and SavedVariables. It then routes through `LegacyImport`.

**It makes no network request.** Every URL in the entire addon was enumerated: all of them are comment headers inside bundled third-party libraries (LibDeflate, AceConfig, LibQTip, LibStub, LibSharedMedia). **The addon never contacts LazyGrip.net or any other host.** The Migrate path is entirely local.

Therefore the 2026-07-30 website commit has **no effect on it**. Verified against the current release **v2.3.16** (SHA-256 `5c1499cf695b1c82…`, CurseForge file ID 8537834), searching every `.lua`, `.xml` and `.toc` file:

| Field | References in the entire addon |
|---|---|
| `PlatformID` / `platformId` | **0** |
| `HelpURL` / `helpUrl` | **0** |
| `gseVersion` (GRIP camelCase) | **0** |
| `GSEVersion` | 7 — recorded as `importMeta.sourceVersion`, i.e. which GSE version it read from, not an owner link |
| `Checksum` | copied to `importMeta.sourceChecksum` (`LegacyImport.lua:738-739`, `ImportPreview.lua:881-882`) and **never validated** against anything |

**The website was changed on 2026-07-30. The addon — which is the subject of the CurseForge complaint — was not.** The identifier that binds a sequence to its author's GSE.Tools account does not exist anywhere in GRIP's code, in the current release, on either import path.

**On the correction it requires.** The package's earlier finding that the LazyGrip converter strips `PlatformID`, `HelpURL` and `Checksum` was **accurate as at 2026-07-12 and is no longer accurate as at 2026-08-01**. That finding must carry a dated withdrawal in the webtool exhibit. The infringement claim does not depend on it: the addon still discards the fields, the removal of the identifier from every string produced before 2026-07-30 already occurred, and neither the licence nor the consent problem is cured by a metadata field the developer states is *"not shown in the UI."*

---

## 8. Artefacts archived with this exhibit

Stored in **`evidence/lazygrip-site/`**, with `SHA256SUMS.txt`:

| File | SHA-256 |
|---|---|
| `2026-07-09_wayback_lazygrip.net_home.html` | `70d3c3aefa7cbbb5538dda0909e3cf4d75016e0d6f5ea10db861fdd5bbac2304` |
| `2026-07-09_wayback_lazygrip.net_tos.html` | `953f6a48b24097de35a91423b2197f188c14037ce1f04eac0cef248728d2d9ce` |
| `2026-08-01_lazygrip.net_home.html` | `5c11eb90c3e66670fe398a44d35675f7a91b5be7e41f89c05472bbe4501d4f02` |
| `2026-08-01_lazygrip.net_about.html` | `f1497088504a979603cedff7c42492981521b3fe6cfef409db3ecd0cfd89929e` |
| `2026-08-01_lazygrip.net_privacy.html` | `f9eedf3a4b3ca3744707d962f7dc16b43010fbd488aca80854bac7133dfebc34` |
| `2026-08-01_lazygrip.net_tos.html` | `1785e878cf308c34e1e5b29b66a6b159173590e8648f8e098633e54651436a93` |
| `2026-08-01_lazygrip.net_workshop.html` | `248255578e10f0ee641f9df9b7cb85e54c46441232d6de38a07a2b8606dae68f` |
| `2026-08-01_lazygrip.net_workshop-convert.html` | `fde33bf2d1143fdb975cbd8d0a58b916f2f79deea7808aff30a306a303f8f6fd` |
| `gseToGrip.ts_main_2026-08-01.ts` | `b4be3948bbef2bc816db40a86fdfac290b4be10fa497b941c6b6deab1e6ffe10` |
| `authorLock.ts_main_2026-08-01.ts` | `74cfc7b4a433d44745dec4dd171c9eec6d38030e5d2fb0640ca7937d3b9d996d` |
| `api-workshop-convert-route.ts_main_2026-08-01.ts` | `4624d84221f2a405a944402399df0b6f0542286b35e2d59469e96d2eb540a84c` |

**Independently re-checkable without these files:**

- Archived pages: `https://web.archive.org/web/20260709134941/https://lazygrip.net/tos` and `…/20260709134931/https://lazygrip.net/`
- Commits: `https://github.com/lazygrip/lazygrip-gg/commit/<sha>` for `234fcd2`, `8d541bc`, `6dea7e0`, `baeb88d`, `85e7e73`, `6c40530`, `d3cd7f5`, `5a2d328`
- Registry: RDAP `https://rdap.namecheap.com/domain/lazygrip.net`, `https://rdap.arin.net/registry/ip/216.198.79.1`

Should the repository be made private or the commits rewritten, the archived copies and the hashes above stand as the record of its state on 2026-08-01. GitHub commit SHAs are content hashes; a rewritten history produces different SHAs.

---

## 9. Scope and limits

**Verified** — every item in §§2, 3.1–3.2, 4, 5, 6 and 7 rests on a registry record, a live HTTP header, an Internet Archive snapshot, or a public commit object, each cited.

**Quoted, not characterised** — the two admissions in §3.3 and §6.2 are reproduced verbatim from public commit messages written by the GRIP-EMS developer.

**Not verified** —
- Whether the DMCA agent has since been registered with the U.S. Copyright Office. The operator's own commit message of 2026-07-31 states it was not yet filed. The Office's public directory was not successfully queried.
- Whether `edosta@proton.me` corresponds to any handle used elsewhere in this package.
- Whether the Workshop credit "Beard3d_Gamer" is the same person as any Discord account of similar name, beyond what is separately sourced in `evidence/discord/captures.md`.
- Any motive for the 2026-07-30/31 changes. Only the sequence of dates and the actors' own stated reasons are recorded.

**Not claimed** —
- That the operator lacks a safe harbour. § 512 is a defence to be raised and adjudicated, not decided here; §6.4 records only the operator's own statement of its filing position.
- That the source repository being MIT-licensed has any bearing on third-party sequence content. The MIT licence covers the site's own program code, not the works users upload.
- That the presence of `authorLock.ts` implies any particular treatment of the rights holder's works.

**Relationship to the main complaint.** Nothing here alters the claim in `curseforge-complaint-final.md`, which concerns the **GRIP-EMS addon on CurseForge** — its reproduction of third-party All-Rights-Reserved sequences, its omission of `PlatformID`, and its redistribution paths. This exhibit establishes the operator and infrastructure behind the associated conversion website, dates a change in that website's behaviour, and records two admissions relevant to affiliation and to licensing.
