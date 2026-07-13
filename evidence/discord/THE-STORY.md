# The Story — House of Macros, in their own words

**For:** Larry Thiessen (ScaryLarryGames) and Timothy Luke (GSE author).
**What this is:** a plain-English narrative of what House of Macros' own Discord messages show happened, over roughly March–June 2026. Every claim below is backed by a verbatim quote and a decoded, authoritative timestamp in `captures.md` — this file is the readable story; `captures.md` is the receipts.
**What this is not:** a legal conclusion. It's the facts, told in order, so a reader — you, Timothy, or a lawyer — can see the shape of it at a glance.

**A note on the model (so "paywall" isn't misread):** The **GSE addon is 100% free** (on CurseForge). Timothy Luke's Patreon buys only **two optional creator quality-of-life features** — *opening the Editor in combat* and *mass-exporting sequences* — a supporter perk, not a content gate. **ScaryLarryGames publishes all his current content free on CurseForge.** A **sequence is not the addon** and is never required: anyone can write their own anytime on the free version. (A few creators do choose to paywall *their own* sequences, but that is their content, not the addon.) So House of Macros' "pay the Patreon / bypass the paywall" framing below is *their* characterization, and it is false at the root — there is no paywall on the addon. What the record actually shows is **copyright** conduct — reverse-engineering the free, All-Rights-Reserved addon and redistributing content without permission — not paywall bypass. Where quotes below say "paid members" or "patreon edition," those are the speakers' own words, preserved verbatim; they do **not** mean the content was gated.

---

## The short version

**House of Macros** — a WoW macro Discord **owned by MFDOOM** — is where most of this played out. **GRIP-EMS** (the addon) and **LazyGrip.net** (its companion website) belong to **sirsataana ("Sataana")**, who carries the "Developer" role in House of Macros and also runs his own separate server, **"GRIP / Temptation / Sataana."** MFDOOM, the House of Macros owner, holds the "Operations" role. (Sataana's real identity, per his own publicly-linked accounts on his CurseForge profile, appears to be **Jesper Driessen** — GitHub `JesperLive`, Facebook `JesperDriessen`, Patreon `cw/JesperLive`.) Over several months, in House of Macros' public channel, members of that team:

1. Got caught by the rights holder redistributing his (and other GSE creators') All-Rights-Reserved sequences without permission — which is why he banned them from GSE United and allied servers.
2. Spent a public Discord conversation, in detail, working out **how to bypass GSE's security system** so they could keep pulling in GSE creators' content without permission — and floated using **AI to read Timothy Luke's private GitHub commit history** to reverse-engineer it.
3. Had a member state, in writing, that a version with the protective data "stripped out" for mass release "would be against licensing" — and pre-wrote his own alibi for when someone found one.
4. Discussed the rights holder's Patreon by name, including his exact supporter count, in a message pushing the idea that a user could pay a creator once and then get the same content forever through their tool — a premise that is false, since the content is free to begin with.
5. Got confronted — with someone accusing them of building the whole thing with AI — and, rather than deny it, the developer said everyone does that, pointed at GSE's own commit history to prove it, and claimed he'd "not heard ANYTHING" from Timothy Luke or anyone at GSE.
6. In the developer's own separate, more private Discord, confirmed AI use isn't hypothetical — it's how he works every day, on a paid $200/month plan — and separately admitted, again, to sharing a creator's content across "MANY Discords," one day before the same topic came up again back in House of Macros.

None of this required guesswork. It's all typed by them. Most of the core plan is inside a single nine-hour window on one day — **April 30, 2026** — in House of Macros. The rest spans from March through June, across two Discord servers.

---

## The timeline

### Before the story starts: friction is already public (2026-03-21)

By late March, there was already open conflict between the rights holder and House of Macros. Sataana posted a long message addressed directly to **"SLG"** — the rights holder, by name — after someone accused GRIP of being "all created by AI" with the developer having "zero clue how to fix it himself."

Sataana didn't deny it. He wrote back: *"I use AI. Tim uses AI. Everyone with half a brain uses AI in 2026."* He'd gone and pulled Timothy Luke's own public GitHub history to make the point — down to the exact commit for GSE's 777-line checksum system, showing it was AI-co-authored too. Then he offered to talk privately, said he hadn't heard *"ANYTHING from Tim, or ANYONE related to WLM or GSE,"* and signed off *"Live and let live."*

A House of Macros member, HomeTeemo, replied approvingly and referenced people getting *"banned because of the server they were in"* and complaining about it on Reddit.

**So going in: both sides already knew about each other. The rights holder had already banned House of Macros members from GSE United. House of Macros already knew it, resented it, and was already publicly discussing the AI question — six weeks before the events below.**

### April 30, 2026 — the day it all comes together

This single day carries almost the entire weight of the record.

**12:38 AM–PM (exact: 12:38–12:42 UTC).** Sataana opens with the goal, in his own words:

> *"how to bypass the new GSE security system that wont allow import unless it includes some sort of secret stuff encoded by their gse tools website thing"*

CzarTheMad, a server moderator, answers immediately with a method:

> *"Perhaps it would be easier for me to strip the gse tools stuff from gse"*

CzarTheMad then admits the real fear driving all of this — that Timothy Luke will make GSE's protection too hard to defeat:

> *"I'm worried you'll stop the conversation in addon. Or TL will do so much obfuscating that it makes it time prohibited"*

Sataana walks him through it like a project plan: there are two ways to do this — "migrate" (read GSE's data live off a running copy) or "import" (crack the string format itself, which is harder). Then he lays out exactly how to crack it:

> *"In theory (I cant advise it since the GitHub is under ARR Licence) you can look at what TL has committed regarding GSE / GSE.tools / Companion App HERE and go through each and every one to figure out the system. **(Maybe some good AI can do it)** And you can do the same with the Companion App source code (Again, legally I cant advice it) — which if you combine it, should give you at least a good starting off point."*

He knows exactly what he's describing — he says so twice, citing the ARR license by name and disclaiming legal advice both times, then adds:

> *"Disclaimer: This is not advice, this is just philosophical thinking out loud, I take no responsibility for anything that happens as a result of my out loud thinking"*

**2:54 PM (14:54 UTC).** Sataana drops in the phrase that should mean something very specific and doesn't match what he just described:

> *"You could always 'Clean-Room' something"*

Clean-room reverse engineering is a real, defined process — one team studies the original, writes a specification with zero code, and hands it to a *second, walled-off* team who never saw the original to build something new. Nothing in this conversation describes that. It describes one person reading the original creator's actual commits, with AI, to build a copy. Using the term here doesn't make it clean-room; it just shows Sataana knew the term existed.

**4:24 PM (16:24 UTC) — under four hours after "how to bypass":**

> *"Kind of solved it, not 100% happy though, because see what happens when I make it narrow 😏"*

— with a video attached, showing his own screen.

**9:17 PM (21:17:21 UTC), same day.** The conversation turns to money, and CzarTheMad names the rights holder specifically, with a number attached:

> *"Slg has 84 paid members but I can't see how much he's making from Patreon"*
> *"Just from Patreon"*

**"Slg" is Larry Thiessen — ScaryLarryGames.** This is House of Macros discussing his Patreon, by name, with his exact paid-member count, on the very day the team confirmed they'd cracked GSE's import protection. (Permalink and snowflake-decoded time in `captures.md`; message ID `1499520058752372977`.)

**The same money logic resurfaces later — 2026-06-20, ~7 weeks on.** Sataana lays out the business rationale for the whole pipeline, unprompted. (This message is dated **2026-06-20 06:24:17 UTC**, not April 30 — an earlier draft of this narrative grouped it with the 84-members line above as if same-day; it isn't. It's a separate, later message on the same theme, ID `1517777091926687805`.):

> *"I don't think Sequence Creators know how this affects them either, even if they are GSE creators... Like, if a user prefers using EMS, instead of GSE, but is fine paying the Patreon for the Sequence Creator to get the GSE strings and then import them in to EMS, they still make the money, right... But then, GSE destroys that income / business be nuking those users..."*

That the same crew was still reasoning out loud about a creator's Patreon income two months after the bypass work — is itself part of the pattern.

### June 17–18, 2026 — two servers, one day apart, same story

Two months later, the same conduct surfaces again, in two different Discords, a single day apart.

**June 17, in Sataana's own server ("GRIP / Temptation / Sataana" — the separate, more private "GRIP Discord" he'd mentioned).** MFDOOM — who **owns House of Macros** — says, plainly (his "my discord" is House of Macros):

> *"if you were in my discord — he got you. he spazzed out on us pretty hard cuz we shared the patreon edition that you can get from their own bot/site"*

Sataana confirms it wasn't small: *"I think up to a point that version was shared in MANY Discords."* Then he says why it matters going forward:

> *"Hence, never a paid version of EMS 😄 Drama voided 😤"*

Sataana is saying, out loud, that a creator's content got shared around, the creator found out and was upset, and the lesson the team took from it wasn't "don't do that" — it was "don't charge for our own thing, so we can't get accused of the same thing." (Whether the creator in question was Larry specifically isn't confirmed yet — that's still open. But the conduct described — take someone's content, hand it out, watch them react — is the exact thing this whole story is about.)

**June 18, back in House of Macros.** CzarTheMad brings up the same idea, and says the quiet part outright:

> *"hypothetically i want to make a version with it stripped out and let the masses have it, but we know that'd be against licensing, so if you happen see one out there it wasnt me"*

He states, plainly, that he knows a stripped, mass-released version would violate the license — and pre-writes his own denial for the day it shows up.

**One day apart. Two different people. Two different servers. Same subject.** This isn't a single bad moment in April — it's a pattern that was still alive and being talked about in June, in more than one place.

---

### A second server confirms the AI method as routine, not hypothetical

In Sataana's own, separate Discord — the one referenced above as the real "GRIP Discord" — the AI question comes up again, this time as plain fact rather than a proposal. Someone asks about running something "through Claude." Sataana's answer:

> *"All my shit is Claude"*

He goes further: he's on Claude's $200-a-month tier, and says over half his monthly usage goes to "just making sure my AI behaves and knows things." Two other regulars — MFDOOM and TheKuhtas — separately confirm they use Claude or Gemini specifically for understanding and writing Lua code. This isn't a one-off — it's how this whole team works, day to day. It's the same method Sataana proposed using on Timothy Luke's commit history back on April 30th, just now described as his normal habit rather than a hypothetical.

The same server also turned up who's behind the anti-GSE YouTube video shared as a Reddit post in House of Macros: a creator called **TheKephas**, whose video was cross-posted in both servers under the same title, "We Need to Talk About the GSE Addon Community."

## What backs this up, beyond the words

- **The role structure isn't casual.** House of Macros has named roles: Sataana is tagged "Developer," MFDOOM and itmeteemo are tagged "Operations," bearded_dad_bod/CzarTheMad/Pershizzle are "BETA Testers." This is an organized team, not a scattered fan chat.
- **A hostile PR push ran in parallel.** CzarTheMad shared a Reddit post titled *"We Need to Talk About the GSE Addon Community,"* describing GSE as having a "kill switch to corrupt" and "invasively reading" — around the same period as the ban complaints and the bypass conversation. CzarTheMad separately remarked it was *"wild... that some random german wow video blog picked up the GSE drama."*
- **Sataana's working method matches what he proposed.** Separately, he described how he actually builds features: turn on WoW's combat logging, run a test, then *"tell Claude to parse the Combatlog"* — feeding it reference material "so it can pretend it kinda knows" the domain. That's the same method — feed AI raw data, have it work out the system — he proposed using on Timothy Luke's commit history.
- **The banned members confirm the ban, and why.** Tony_Hronik: *"I was removed from GSE:nited and OAK discord."* Sataana, discussing it: *"If SLG was a mod / admin with banning powers on that Discord, I can only assume it was him... he banned people from every server he could."* This matches the rights holder's own account of why he acted — House of Macros members were redistributing creators' All-Rights-Reserved GSE content without permission.

---

## What this does and doesn't prove

**Solidly established, in their own words:**
- Explicit, stated intent to defeat GSE's protective encoding ("bypass the new GSE security system").
- A proposed method — AI-assisted study of Timothy Luke's private/licensed commit history — floated by the developer himself, with an explicit ARR-license citation and a legal disclaimer attached both times he described it.
- A team member's direct admission that a stripped, mass-distributed version would violate the license, plus a pre-built denial.
- Direct, named discussion of the rights holder's Patreon and his content — under a false assumption that it was gated (it is free).
- A timeline in which "figure out how to bypass it" and "kind of solved it" are under four hours apart.

**What the record does NOT establish, and shouldn't be overclaimed:**
- Whether the AI-assisted plan is what *actually* produced GRIP's code, versus manual work — the forensic code diff (`grip-vs-gse-forensic-comparison.md`) shows the shipped code is independently written, not copied line-for-line. This Discord record is about **stated intent and method**, not a confession that specific lines were AI-generated from GSE's source. Both things can be true at once: independently-written code that was built *by studying* GSE's original with AI assistance is still a derivative work, and the method described here is exactly that.
- Whether "Clean-Room" was ever actually followed as a real process — nothing here shows the walled-off second team a genuine clean-room requires. If anything, invoking the term without following its discipline undercuts a defense built on it, not supports one.
- The private side of this — DMs, the separate "GRIP Discord" Sataana mentioned, or any staff-only channel this account can't see. This document only covers what's visible in House of Macros' #general. There is very likely more.

---

## What's still open

- Full permalinks/timestamps for the remaining lines in the April 30th thread not yet individually confirmed (a few are captured only via the search-panel snippet).
- The video Sataana posted at 4:24 PM UTC on April 30 — not yet downloaded.
- The full GitHub URL Sataana linked (pointed at Timothy Luke's commit history) — attempted, not yet captured cleanly.
- Identity/context for **Tony_Hronik**, **rtx**, and **peytonjo** — newly surfaced names not on the original watch list.
- Anything in DMs or the separate "GRIP Discord" server referenced by Sataana — outside this account's visibility.

See `captures.md` for the full verbatim log, every permalink, and the complete action-item list.
