# The Story — House of Macros, in their own words

**For:** Larry Thiessen (ScaryLarryGames) and Timothy Luke (GSE author).
**What this is:** a plain-English narrative of what House of Macros' own Discord messages show happened, over roughly March–June 2026. Every claim below is backed by a verbatim quote and a decoded, authoritative timestamp in `captures.md` — this file is the readable story; `captures.md` is the receipts.
**What this is not:** a legal conclusion. It's the facts, told in order, so a reader — you, Timothy, or a lawyer — can see the shape of it at a glance.

---

## The short version

House of Macros is the Discord home of **GRIP-EMS**, a WoW macro addon, and **LazyGrip.net**, its companion website — both run by **sirsataana ("Sataana")**, who carries the server's "Developer" role. Over several months, in their own public channel, members of that team:

1. Got caught by the rights holder redistributing his Patreon-locked sequences (and other GSE creators' work) for free — which is why he banned them from GSE United and allied servers.
2. Spent a public Discord conversation, in detail, working out **how to bypass GSE's security system** so they could keep pulling in GSE creators' content without permission — and floated using **AI to read Timothy Luke's private GitHub commit history** to reverse-engineer it.
3. Had a member state, in writing, that a version with the protective data "stripped out" for mass release "would be against licensing" — and pre-wrote his own alibi for when someone found one.
4. Discussed the rights holder's Patreon by name, including his exact paid-subscriber count, in a message explaining how a user could pay a creator once and then get the same content forever through their tool.
5. Got confronted — with someone accusing them of building the whole thing with AI — and, rather than deny it, the developer said everyone does that, pointed at GSE's own commit history to prove it, and claimed he'd "not heard ANYTHING" from Timothy Luke or anyone at GSE.

None of this required guesswork. It's all typed by them, in a channel with 50-60 members, most of it inside a single nine-hour window on one day: **April 30, 2026**.

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

> *"In theory (I cant advise it since the GitHub is under AGPL Licence) you can look at what TL has committed regarding GSE / GSE.tools / Companion App HERE and go through each and every one to figure out the system. **(Maybe some good AI can do it)** And you can do the same with the Companion App source code (Again, legally I cant advice it) — which if you combine it, should give you at least a good starting off point."*

He knows exactly what he's describing — he says so twice, citing the AGPL license by name and disclaiming legal advice both times, then adds:

> *"Disclaimer: This is not advice, this is just philosophical thinking out loud, I take no responsibility for anything that happens as a result of my out loud thinking"*

**2:54 PM (14:54 UTC).** Sataana drops in the phrase that should mean something very specific and doesn't match what he just described:

> *"You could always 'Clean-Room' something"*

Clean-room reverse engineering is a real, defined process — one team studies the original, writes a specification with zero code, and hands it to a *second, walled-off* team who never saw the original to build something new. Nothing in this conversation describes that. It describes one person reading the original creator's actual commits, with AI, to build a copy. Using the term here doesn't make it clean-room; it just shows Sataana knew the term existed.

**4:24 PM (16:24 UTC) — under four hours after "how to bypass":**

> *"Kind of solved it, not 100% happy though, because see what happens when I make it narrow 😏"*

— with a video attached, showing his own screen.

**9:17 PM (21:17 UTC), same day.** The conversation turns to money. Sataana lays out the business logic, unprompted:

> *"I don't think Sequence Creators know how this affects them either, even if they are GSE creators... Like, if a user prefers using EMS, instead of GSE, but is fine paying the Patreon for the Sequence Creator to get the GSE strings and then import them in to EMS, they still make the money, right... But then, GSE destroys that income / business be nuking those users..."*

Right after that, CzarTheMad names the rights holder specifically, with a number attached:

> *"Slg has 84 paid members but I can't see how he's making from Patreon"*
> *"Just from Patreon"*

**"Slg" is Larry Thiessen — ScaryLarryGames.** This is House of Macros discussing his Patreon, by name, with his exact paid-member count, on the very day the team confirmed they'd cracked GSE's import protection.

### Roughly seven weeks later (2026-06-18) — it wasn't a one-off

CzarTheMad brings up the same idea again, and this time says the quiet part outright:

> *"hypothetically i want to make a version with it stripped out and let the masses have it, but we know that'd be against licensing, so if you happen see one out there it wasnt me"*

He states, plainly, that he knows a stripped, mass-released version would violate the license — and pre-writes his own denial for the day it shows up. Coming almost two months after the original bypass conversation, this shows the idea didn't die in April. It was still being discussed as something someone might actually do.

---

## What backs this up, beyond the words

- **The role structure isn't casual.** House of Macros has named roles: Sataana is tagged "Developer," MFDOOM and itmeteemo are tagged "Operations," bearded_dad_bod/CzarTheMad/Pershizzle are "BETA Testers." This is an organized team, not a scattered fan chat.
- **A hostile PR push ran in parallel.** CzarTheMad shared a Reddit post titled *"We Need to Talk About the GSE Addon Community,"* describing GSE as having a "kill switch to corrupt" and "invasively reading" — around the same period as the ban complaints and the bypass conversation. CzarTheMad separately remarked it was *"wild... that some random german wow video blog picked up the GSE drama."*
- **Sataana's working method matches what he proposed.** Separately, he described how he actually builds features: turn on WoW's combat logging, run a test, then *"tell Claude to parse the Combatlog"* — feeding it reference material "so it can pretend it kinda knows" the domain. That's the same method — feed AI raw data, have it work out the system — he proposed using on Timothy Luke's commit history.
- **The banned members confirm the ban, and why.** Tony_Hronik: *"I was removed from GSE:nited and OAK discord."* Sataana, discussing it: *"If SLG was a mod / admin with banning powers on that Discord, I can only assume it was him... he banned people from every server he could."* This matches the rights holder's own account of why he acted — House of Macros members were redistributing Patreon-locked and other creators' GSE content.

---

## What this does and doesn't prove

**Solidly established, in their own words:**
- Explicit, stated intent to defeat GSE's protective encoding ("bypass the new GSE security system").
- A proposed method — AI-assisted study of Timothy Luke's private/licensed commit history — floated by the developer himself, with an explicit AGPL-license citation and a legal disclaimer attached both times he described it.
- A team member's direct admission that a stripped, mass-distributed version would violate the license, plus a pre-built denial.
- Direct, named discussion of the rights holder's Patreon-gated business.
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
