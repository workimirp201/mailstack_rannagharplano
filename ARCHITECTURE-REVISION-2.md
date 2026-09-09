# Architecture revision 2 — webmail, Frontier rDNS, and corrections
### rannagharplano.com · 8 September 2026 · **REVIEW BEFORE DEPLOYMENT — no install commands in this document**

---

# ⛔ STOP — one thing I need you to confirm before anything else

**Your item 11 asks me to check `102.104.58.45`. Last message you told me the Singapore IP is `172.104.58.45`.**

You told me explicitly not to silently change your IP addresses, so I am not choosing for you. Here is the situation:

| Source | Singapore IP |
|---|---|
| Your original brief | `102.104.58.45` |
| Your correction last message ("172.104.58.45 this is the singapore IP") | `172.104.58.45` |
| Your item 11 in this message | `102.104.58.45` |

`172.104.0.0/16` is Linode address space and is used by Linode Singapore. `102.0.0.0/8` is allocated to AFRINIC (Africa) and is not Linode. On that evidence I believe `172.104.58.45` is correct and your item 11 is a paste from the first (wrong) version of the runbook — but **you confirm it, not me.** Run this in the Linode console or on the node itself:

```bash
curl -s https://api.ipify.org; echo
ip -4 addr show
```

**Everything below assumes `172.104.58.45`.** If that is wrong, say so and I will regenerate.

---

# Section 0 — Corrections to the previous runbook

You asked me to identify anything that was wrong rather than quietly fixing it. Six things:

| # | What the previous runbook said | Correction | Severity |
|---|---|---|---|
| 1 | Singapore IP `102.104.58.45` | `172.104.58.45` — corrected in revision 2, pending your confirmation above | **Critical** — every firewall rule, SPF record and Garage peer entry depends on it |
| 2 | Nothing at all about webmail | Stalwart genuinely has no mailbox UI. This was a real gap in my plan, not just an omission of detail. Addressed in §1 | **Major** |
| 3 | "Add `MX 30 mail3`" once mail3 was a full node | **I now recommend against publishing MX 30 in either configuration.** Reasoning in §8.3 — it turns out a third MX buys you almost nothing here, and I did not think that through the first time | Moderate |
| 4 | Stalwart owns TCP 443 exclusively | It can't, once webmail exists. Corrected to an nginx SNI-routing front door in §12 | Moderate |
| 5 | Storage table totalled "~51 GB" on a 50 GB disk with "~1 GB free" | That arithmetic was over-committed before webmail was even added. Recomputed in §16.2, and the honest answer changes your Garage capacity number | **Major** |
| 6 | mail3 was first "never send mail", then "full sender" after your Frontier update | Now settled properly against the actual PTR you have. §6 | Moderate |

---

# 1. Webmail — the choice

## Verified first: Stalwart has no webmail

Stalwart's WebUI has exactly two faces, per its documentation:

- **`/admin`** — the administrator console (accounts, domains, listeners, TLS, queue, reports)
- **`/account`** — the Account Manager, where an end user changes their **password, application passwords, two-factor authentication, aliases and masked email**

No message list. No compose window. No mailbox. You are right, and the previous runbook should have said so.

## The choice: **Roundcube 1.7.x**

I was leaning toward SnappyMail for most of this analysis — no database, self-contained, lighter on a 2 GB node, built-in brute-force lockout. On your priorities 2, 4, 7, 8 and 9 it is the better-designed option.

**Then I looked at the release histories, and that settled it.**

| | Roundcube | SnappyMail |
|---|---|---|
| Latest release | **1.7.4 — 6 September 2026** (two days ago) | **v2.38.2 — 9 October 2024** |
| Release before that | 1.7.3 — 9 August 2026; 1.7.2 — 5 July 2026 | v2.38.1 — 8 October 2024 |
| Releases in the last 12 months | ~8 (1.7.x stable **and** 1.6.x LTS in parallel) | **0** |
| What 1.7.4 fixed | CSS declaration smuggling, CSS property injection, email header injection, stored XSS, SSRF bypass | — |

> **How I read the dates, so you can check my reasoning:** GitHub hides the year for anything in the last twelve months and shows it for anything older. Every SnappyMail release renders with an explicit `2024`; every recent Roundcube release renders without a year. That is a consistent, strong signal — but verify it yourself before you commit:
> ```bash
> curl -s https://api.github.com/repos/roundcube/roundcubemail/releases/latest    | grep -E '"tag_name"|"published_at"'
> curl -s https://api.github.com/repos/the-djmaze/snappymail/releases/latest      | grep -E '"tag_name"|"published_at"'
> ```

For an internet-facing PHP application that reads untrusted HTML from strangers, **an unmaintained codebase is disqualifying**, regardless of how much nicer its architecture is. Webmail is the highest-risk component in this entire deployment: it parses hostile HTML and CSS, it holds session cookies for every mailbox, and it sits on the same host as your database primary. It needs a maintainer shipping security fixes on a monthly cadence. Roundcube has one. SnappyMail, on this evidence, does not right now.

### Roundcube against your nine priorities

| Your priority | How Roundcube does | Notes |
|---|---|---|
| 1. Reliable with Stalwart | ✅ | Standard IMAP4rev1 + SMTP submission. Roundcube is the most widely deployed webmail there is, so edge cases tend to be found and fixed by someone else first. *I could not check community reports — web search is unavailable in this session — but there is no documented Stalwart/Roundcube incompatibility in either project's docs.* |
| 2. Easy maintenance | ⚠️ | Honestly, the weakest point. Upgrades need `installto.sh` and a database schema step. This is the price of priority 3 |
| 3. Secure | ✅ | Active security process, coordinated disclosure, parallel LTS branch. See §14 for the hardening |
| 4. Mobile/browser | ✅ | The **Elastic** skin is responsive and works properly on phones. Set it as the default and don't offer the others |
| 5. IMAP + SMTP | ✅ | Both, configured server-side so users never see a port number |
| 6. Same accounts | ✅ | Authenticates directly against Stalwart IMAP. No user database, no sync, no provisioning |
| 7. No second mail database | ✅ **with one setting** | Roundcube *can* cache message bodies in SQL. We turn that off — `messages_cache = false`. See §13 |
| 8. Easy to upgrade | ⚠️ | Tarball + `installto.sh`. Scripted for you |
| 9. Doesn't interfere | ✅ | ~200 MB RAM, ~1 GB disk, one small extra PostgreSQL database. See §16.2 |

**The one thing you give up by not choosing SnappyMail** is the no-database simplicity. §13 shows exactly how small that database is and why it is not a "second mail store".

**If Roundcube's maintenance stops or SnappyMail restarts,** switching costs an afternoon. The webmail tier is stateless by design here — messages live in Stalwart, contacts can live in Stalwart via CardDAV. All you lose is per-user preferences.

---

# 2. Where webmail runs — **Option A: mail2 only**

## The reasoning, in one sentence

**Webmail on mail2 adds no new single point of failure, because webmail cannot work without the database primary, and the database primary is on mail2.**

Work it through:

| Scenario | Can webmail serve mail? | Why |
|---|---|---|
| Webmail on mail2; mail2 dies | ❌ | Webmail is gone — **and so is IMAP, JMAP and SMTP acceptance for the whole cluster**, because the data store is gone |
| Webmail on mail1 too; mail2 dies | ❌ | The mail1 webmail loads, shows a login box, and then fails — because the IMAP server it talks to has no data store |

Option B does not raise the availability ceiling. It just gives you three PHP stacks to patch instead of one, on the component with the largest attack surface in the deployment.

## The three options, judged

| | Option A — mail2 only | Option B — all three nodes | Option C — separate VPS |
|---|---|---|---|
| Availability gained | baseline | **none** (see above) | **none** (still needs mail2's DB) |
| PHP stacks to patch | 1 | 3 | 1 |
| Extra cost | £0 | £0 | a 4th server, forever |
| IMAP latency | ~0 ms (same host) | 200 ms from mail1 | depends where it sits |
| Real benefit | — | — | isolates the PHP attack surface from the mail server — a genuine security argument |
| Verdict | ✅ **Chosen** | ❌ complexity for nothing | ❌ only if you later want the isolation, and you said not to add servers unnecessarily |

Option C's isolation argument is real and I want to be fair to it: if webmail is ever compromised, on Option A the attacker is already on the host holding your database primary and your Garage node. If that risk ever starts to bother you, Option C is the upgrade — not Option B.

## "What happens if mail2 goes down?"

Exactly what happens to the rest of your mail service, and no worse:

1. Webmail returns a connection error. IMAP, JMAP and outbound are also down. Inbound mail queues **at the sending servers** and is not lost.
2. You promote a standby (mail3 if it's nearby, else mail1) — the existing TEST 8 procedure.
3. **You add one step to that procedure:** run the webmail install on the promoted node (~3 minutes) and repoint `webmail.rannagharplano.com`.
4. Because Roundcube's data lives in PostgreSQL and PostgreSQL followed the promotion, **every user's preferences, contacts and signatures are already there.** Nothing to restore.

That is deliberately a *runbook step*, not a *standing service*. It costs three minutes during an outage you are already handling, and it costs nothing the other 364 days.

---

# 3. Webmail DNS

```
webmail.rannagharplano.com.    60  IN  A   104.237.138.198
```

**An A record, TTL 60. Not a CNAME.**

- **A, not CNAME to `mail.`** — because webmail must be able to move independently of the mail endpoint. During a failover you might want webmail on a different node from the one you point `mail.` at. A CNAME chains them together.
- **TTL 60** — same reason `mail.` and `db.` are 60. It is a failover lever.

## Why `webmail.` and not `mail.` — you're right, and here's the technical reason

Your preference is also the technically correct choice:

- `mail.rannagharplano.com` is the **protocol endpoint**. Stalwart terminates TLS for it and serves IMAP (993), SMTP submission (465), JMAP, WebDAV, autoconfig, `/admin` and `/account` on it. It is referenced by your SRV records and by every mail client's autoconfiguration.
- `webmail.rannagharplano.com` is a **web application**. nginx terminates TLS for it and hands requests to PHP.

Two different servers terminating two different TLS sessions. Keeping them on separate names means:

1. Each gets its own certificate from its own mechanism (§15) — no shared-key coupling.
2. You can move webmail to another node, or to a separate VPS later (Option C), by changing one A record.
3. A webmail compromise does not automatically imply a certificate that covers your mail endpoints.
4. Users get a name that means what it does.

---

# 4. Webmail login

## What the user sees

```
URL:       https://webmail.rannagharplano.com
Username:  rana@rannagharplano.com          ← full email address
Password:  their normal Stalwart password
```

**That is the entire login form.** No server, no port, no encryption dropdown. Everything below is configured once, server-side, in `/var/www/roundcube/config/config.inc.php`.

## What Roundcube is configured with

| Setting | Value | Why |
|---|---|---|
| `imap_host` | `ssl://mail.rannagharplano.com:993` | **The logical endpoint, never a node name.** It follows your failover DNS automatically |
| IMAP encryption | Implicit TLS (SSL/TLS) | No STARTTLS downgrade window |
| `smtp_host` | `ssl://mail.rannagharplano.com:465` | See below |
| SMTP encryption | Implicit TLS (SSL/TLS) | |
| `smtp_user` / `smtp_pass` | `%u` / `%p` | Reuses the user's own login — **every outgoing message is authenticated as that user**, so your per-user rate limits and quotas apply. Never a shared relay account |
| `username_domain` | `rannagharplano.com` | Lets someone type `rana` and get `rana@rannagharplano.com` |
| Certificate verification | **on** | The cert for `mail.rannagharplano.com` validates properly. Do not add `verify_peer => false` |

## Which SMTP port: **465, not 587**

| | 465 — implicit TLS (SMTPS) | 587 — STARTTLS |
|---|---|---|
| TLS starts | immediately, before any protocol data | after a plaintext greeting and an upgrade command |
| Downgrade attack | not possible — there is no plaintext phase | possible if the client doesn't *require* STARTTLS (a MITM strips the `250-STARTTLS` capability) |
| Standards position | **RFC 8314 recommends implicit TLS for submission** | still valid, but the fallback rather than the preference |
| In your firewall plan | already open on mail2 | currently closed, deliberately |

Use **465**. It also means you never have to open 587, which keeps your listener list one line shorter. This satisfies your own requirement 14 ("no plaintext SMTP authentication") by construction rather than by configuration.

> ⚠️ One consequence worth knowing now: because Roundcube runs *on* mail2 and connects to `mail.rannagharplano.com`, **failed webmail logins reach Stalwart from mail2's own public IP**, not from the attacker's. If you leave auto-ban untouched, a webmail brute-force attack will get **mail2 itself banned**, cutting off webmail for everyone. §14 handles this properly.

---

# 5. The Frontier reverse-DNS problem

## What you have right now

```
$ dig +short -x 47.190.50.190
47-190-50-190.41ef09f3ac684fe6be7ab554f34a619d.ip.frontiernet.net.

$ dig +short mail3.rannagharplano.com
47.190.50.190
```

Your forward DNS is correct. Your reverse DNS resolves — it just resolves to a Frontier-generated name. Two separate problems with that name:

1. **It doesn't match your forward name.** A receiver doing forward-confirmed reverse DNS (FCrDNS) sees `mail3.rannagharplano.com → 47.190.50.190 → 47-190-50-190.…ip.frontiernet.net`. The chain does not close. Many receivers treat that as a mismatch.
2. **It looks generated.** The IP embedded in the hostname with dashes, plus a 32-hex-character label, plus `ip.frontiernet.net`, is the classic signature of dynamically-assigned consumer space. Several large receivers pattern-match exactly this shape and reject or heavily penalise mail from it regardless of SPF, DKIM and DMARC all passing.

## Why you cannot fix this in your own DNS zone

This is the part worth understanding properly, because it is the reason "just add a PTR record" is not an option.

**Forward DNS authority follows domain-name ownership. Reverse DNS authority follows IP-address allocation.** They are two different, unrelated delegation trees.

A reverse lookup for `47.190.50.190` is not a query about `rannagharplano.com`. The resolver reverses the octets and asks for a `PTR` record at:

```
190.50.190.47.in-addr.arpa
```

and it walks *that* tree from the root:

```
.                          root servers
 └─ arpa.                  IANA
     └─ in-addr.arpa.      IANA / the RIRs
         └─ 47.in-addr.arpa.        delegated to ARIN
             └─ 190.47.in-addr.arpa.       delegated by ARIN to Frontier
                 └─ 50.190.47.in-addr.arpa.      Frontier's nameservers
                     └─ 190.50.190.47.in-addr.arpa.   ← the PTR lives here
```

**Frontier's nameservers are authoritative for that zone because ARIN allocated the address block to Frontier.** Your registrar and your DNS host have no relationship to that tree at all.

If you create a record called `190.50.190.47.in-addr.arpa` inside your `rannagharplano.com` zone, it is inert. No resolver on earth will ever query your nameservers for it, because your nameservers are not in the delegation chain for `in-addr.arpa`. The record would simply never be looked up. **Owning the domain gives you no authority over the IP's reverse zone.**

This is also why the rDNS you have was set by Frontier without asking you: they are the only party who *can* set it.

## Exactly what to ask Frontier — Request 1 (do this first)

Open a Frontier **Business** support ticket. Ask for a network/IP engineer if the first line doesn't recognise the term.

> **Subject: Reverse DNS (PTR) record request for static IP 47.190.50.190**
>
> We have a Frontier Business static IP assignment. We operate a mail server on `47.190.50.190` and need the reverse DNS to match its forward hostname so that receiving mail servers accept our mail.
>
> **Please set the PTR record for `47.190.50.190` to `mail3.rannagharplano.com`.**
>
> Forward DNS is already in place and you can verify it:
> `dig +short mail3.rannagharplano.com` → `47.190.50.190`
>
> The current PTR is `47-190-50-190.41ef09f3ac684fe6be7ab554f34a619d.ip.frontiernet.net`, which does not match our forward hostname. This mismatch causes major mail providers to reject or spam-filter our outbound mail.
>
> Our full static assignment is `<YOUR /26 HERE — e.g. 47.190.50.128/26>`. If it is easier for you to handle the whole block at once, please see the delegation request below.

For most business accounts this is all it takes. It is a routine request.

## Request 2 — RFC 2317 delegation, if they won't set individual PTRs

If they say they can't do individual records, or you want to control all 61 addresses yourself without a ticket each time, ask for **classless reverse delegation**.

**The problem it solves:** DNS delegation happens on octet boundaries. Your block is a /26 — a quarter of `50.190.47.in-addr.arpa`. Frontier cannot delegate a quarter of a zone by normal means, because there is no name in the tree that represents "the last 64 addresses". RFC 2317 works around this with a level of indirection: Frontier creates an artificially-named sub-zone, delegates *that* to you, and points each individual PTR name at it with a CNAME.

> **Subject: RFC 2317 classless reverse DNS delegation for our /26**
>
> We would like to manage reverse DNS for our static assignment ourselves. Please set up RFC 2317 classless in-addr.arpa delegation.
>
> **Our block:** `<YOUR /26, e.g. 47.190.50.128/26>`
> **Our authoritative nameservers:** `<ns1.yourdnshost.com>`, `<ns2.yourdnshost.com>`
>
> Specifically, in the `50.190.47.in-addr.arpa` zone, please add:
>
> 1. An NS delegation for the sub-zone, e.g.
>    `128/26.50.190.47.in-addr.arpa.  IN NS ns1.yourdnshost.com.`
>    `128/26.50.190.47.in-addr.arpa.  IN NS ns2.yourdnshost.com.`
>    *(Any sub-zone label convention you prefer is fine — `128/26`, `128-191`, or `128-26` — just tell us which one you use so we can create the matching zone.)*
>
> 2. A CNAME for each address in our block pointing into that sub-zone, e.g.
>    `190.50.190.47.in-addr.arpa.  IN CNAME  190.128/26.50.190.47.in-addr.arpa.`
>
> We will then host the `128/26.50.190.47.in-addr.arpa` zone and create the PTR records ourselves.

**What you must send them:** the exact CIDR of your /26 and the hostnames of your nameservers. **What you must get back:** the exact sub-zone label they used — you cannot create your zone without it.

Once delegated, you host a zone containing:

```
190.128/26.50.190.47.in-addr.arpa.  IN PTR  mail3.rannagharplano.com.
```

Not every DNS provider will host a zone with a `/` in its name. Check yours before requesting this — Cloudflare, Route 53 and a self-hosted BIND all will; some registrar DNS panels will not.

## If both requests are refused

Then §6 applies, and it is not a disaster.

---

# 6. mail3 without a matching PTR — the recommended configuration

**Your instruction is correct and I'm following it exactly.** If Frontier refuses:

| | Setting |
|---|---|
| Outbound mail from mail3 | **Relay through mail2.** `mail3 → mail2:465 (authenticated) → internet` |
| SPF | **Do not add `ip4:47.190.50.190`.** mail3 never connects to a foreign MTA, so it never needs SPF authorisation |
| MX | **Do not publish MX 30.** Reasoning in §8.3 — and note this holds even in Configuration A |
| Everything else | **Unchanged.** mail3 stays a full member of the cluster |

## Why relaying is the right answer rather than just disabling outbound

mail3 will generate outbound mail whether you plan for it or not: bounces (DSNs), DMARC and TLS aggregate reports, vacation auto-replies, and Sieve-generated redirects. If outbound is simply disabled, those queue forever and eventually expire silently. Relaying through mail2 means they leave from an IP with correct rDNS and SPF authorisation, and the recipient sees a properly authenticated message.

Set it in **Settings → MTA → Outbound** on mail3:

| Field | Value |
|---|---|
| Outbound strategy | Relay host |
| Relay host | `mail2.rannagharplano.com:465` |
| TLS | Implicit (SMTPS) |
| Authentication | A dedicated Stalwart account, e.g. `relay-mail3@rannagharplano.com`, with submission rights only |
| Fallback | none — if mail2 is down, queue |

Create `relay-mail3@` as a real account with a generated password, no IMAP access, and a low rate limit. Do **not** reuse an admin credential.

---

# 7. *(you skipped item 7 — nothing to answer here)*

---

# 8. Two DNS plans

Records that **differ between A and B are marked 🔶**. Everything else is identical.

## Configuration A — Frontier sets `mail3.rannagharplano.com` as the PTR

| Name | Type | Value | TTL | |
|---|---|---|---|---|
| `mail1` | A | 172.104.58.45 | 300 | |
| `mail2` | A | 104.237.138.198 | 300 | |
| `mail3` | A | 47.190.50.190 | 300 | |
| `mail` | A | 104.237.138.198 | **60** | client + protocol endpoint |
| `webmail` | A | 104.237.138.198 | **60** | 🆕 |
| `db` | A | 104.237.138.198 | **60** | data store endpoint |
| `@` | MX 10 | mail2.rannagharplano.com. | 3600 | |
| `@` | MX 20 | mail1.rannagharplano.com. | 3600 | |
| `@` | TXT (SPF) | 🔶 `v=spf1 ip4:104.237.138.198 ip4:172.104.58.45 ip4:47.190.50.190 -all` | 3600 | |
| `mail1` | TXT (SPF) | `v=spf1 a -all` | 3600 | |
| `mail2` | TXT (SPF) | `v=spf1 a -all` | 3600 | |
| `mail3` | TXT (SPF) | 🔶 `v=spf1 a -all` | 3600 | |
| `<sel>e._domainkey` | TXT | Ed25519 key from Stalwart | 3600 | |
| `<sel>r._domainkey` | TXT | RSA-2048 key from Stalwart | 3600 | |
| `_dmarc` | TXT | `v=DMARC1; p=none; rua=mailto:dmarc-reports@rannagharplano.com; ruf=mailto:dmarc-reports@rannagharplano.com; fo=1; adkim=r; aspf=r; pct=100` | 3600 | ramp to reject over ~5 weeks |
| `mta-sts` | CNAME | mail2.rannagharplano.com. | 3600 | |
| `_mta-sts` | TXT | `v=STSv1; id=20260908000000` | 3600 | |
| `_smtp._tls` | TXT | `v=TLSRPTv1; rua=mailto:tls-reports@rannagharplano.com` | 3600 | |
| `@` | CAA | `0 issue "letsencrypt.org"` | 3600 | |
| `@` | CAA | `0 iodef "mailto:security@rannagharplano.com"` | 3600 | |
| `autoconfig` | CNAME | mail.rannagharplano.com. | 3600 | Thunderbird |
| `autodiscover` | CNAME | mail.rannagharplano.com. | 3600 | Outlook |
| `_autodiscover._tcp` | SRV | `0 1 443 mail.rannagharplano.com.` | 3600 | |
| `_imaps._tcp` | SRV | `0 1 993 mail.rannagharplano.com.` | 3600 | |
| `_submissions._tcp` | SRV | `0 1 465 mail.rannagharplano.com.` | 3600 | |
| `_jmap._tcp` | SRV | `0 1 443 mail.rannagharplano.com.` | 3600 | |
| `_imap._tcp` | SRV | `0 0 0 .` | 3600 | "don't try plaintext" |
| `_submission._tcp` | SRV | `0 0 0 .` | 3600 | |
| `_pop3._tcp` | SRV | `0 0 0 .` | 3600 | |
| **PTR** `104.237.138.198` | PTR | mail2.rannagharplano.com. | — | set at Linode |
| **PTR** `172.104.58.45` | PTR | mail1.rannagharplano.com. | — | set at Linode |
| **PTR** `47.190.50.190` | PTR | 🔶 mail3.rannagharplano.com. | — | **set by Frontier** |

## Configuration B — Frontier refuses (assume this until proven otherwise)

Only four rows change. **Everything else above is identical — do not rebuild your zone.**

| Name | Type | Value | Change |
|---|---|---|---|
| `@` | TXT (SPF) | 🔶 `v=spf1 ip4:104.237.138.198 ip4:172.104.58.45 -all` | **mail3's IP removed** |
| `mail3` | TXT (SPF) | 🔶 `v=spf1 -all` | **explicitly authorises nothing** — states affirmatively that this host never sends |
| `mail3` | A | 47.190.50.190 | unchanged — still needed for cluster, IMAP and webmail |
| **PTR** `47.190.50.190` | PTR | 🔶 `47-190-50-190.…ip.frontiernet.net.` (Frontier's, unchanged) | you accept it |

**A records, MX, DKIM, DMARC, MTA-STS, TLS-RPT, CAA, autoconfig, autodiscover, SRV, webmail and both Linode PTRs are byte-identical between A and B.**

## 8.3 Why MX 30 is not in *either* configuration — a correction to my earlier advice

The previous runbook told you to add `MX 30 mail3` once mail3 was a full node. I've re-derived it and **that was wrong, and it's wrong in Configuration A too.**

A third MX is only ever used when MX 10 and MX 20 are **both** unreachable. Walk through what has to be true for mail3 to be useful in that moment:

| State | Can mail3 accept the message? |
|---|---|
| mail2 down (the DB primary is gone) | ❌ **No.** mail3 has no data store, so it answers `4xx`. The sender queues — exactly as it would have anyway |
| mail2 up but its SMTP listener is down, **and** mail1 also down | ✅ Yes — but this is a narrow double failure |
| Both Linodes down | ❌ No. Same reason as row 1 |

So the third MX helps in precisely one narrow scenario, and in the common scenario (mail2 dies) it helps not at all — because **the thing that makes a third MX necessary is the same thing that makes mail3 unable to serve.**

Against that near-zero benefit:

- In Configuration B it publishes a host with mismatched rDNS as a public mail destination, which some senders use as a low-quality signal about the domain.
- It routes inbound mail over a consumer-grade uplink with no SLA.
- It gives you a third public SMTP surface to patch, monitor and rate-limit.

**Recommendation: publish MX 10 and MX 20 only, in both configurations.** Two MXes on two continents in two datacenters is proper redundancy. Answering "can mail3 receive mail without a matching PTR?" directly: yes, technically — a receiving server's PTR is not checked by senders, PTR matters for the *connecting* host. It is allowed. It is just not worth doing here.

If you want it anyway once Configuration A is in place, it is one record and nothing else changes.

---

# 9. What mail3 can safely do — service by service

Your framing is right: **a missing PTR is an outbound-reputation problem and nothing else.** It does not touch storage, replication, authentication or cluster membership. Here is every service, judged independently.

| | Service | Safe on mail3 without PTR? | Why / conditions |
|---|---|---|---|
| **A** | **Receiving mail** (public MX) | ⚠️ Technically yes, recommended no | A sender never checks the *recipient* server's PTR. It is allowed. But see §8.3 — near-zero benefit, so don't |
| **B** | **Sending mail** (direct to internet) | ❌ **No** | This is the one thing PTR actually governs. Generic rDNS → rejected or spam-filed by major receivers, and it damages the whole domain's reputation, not just this IP. **Relay through mail2 instead** (§6) |
| **C** | **Webmail access** | ✅ Yes, but not chosen | No PTR dependency whatsoever — it's HTTPS. We're not putting webmail here because of §2 (uplink quality and the DB being on mail2), not because of rDNS |
| **D** | **IMAP / JMAP access** | ✅ **Yes, fully** | Pure client-to-server TLS. No reputation system involved. Excellent use for mail3: LAN users get local-speed mailbox access. Restrict 993/443 to your LAN if you don't want it public |
| **E** | **Stalwart cluster communication** | ✅ **Yes, fully** | Zenoh on TCP 7447 between three IPs you control. Authenticated by the cluster secret and your firewall allowlist. Never touches DNS reputation |
| **F** | **Garage replication** | ✅ **Yes, fully** | RPC on TCP 3901, authenticated by a shared 32-byte secret. mail3 is a **first-class Garage node holding a full third replica** — this is one of the most valuable things it does |
| **G** | **PostgreSQL replication** | ✅ **Yes, fully** | TLS + scram-sha-256 streaming replication on 5432. mail3 is a hot standby and — if it's low-latency to mail2 — your **preferred failover target** |

**Summary: 5 of 7 services run at full capability. One is discouraged for unrelated reasons. Exactly one is genuinely blocked, and it has a clean workaround.**

mail3 is not a second-class node. It carries a third of your object storage, a full copy of your database, and it is very possibly the box you promote when the USA node dies. Losing "can send mail directly" costs you nothing you can't get by relaying.

---

# 10. Port 25 tests

## Outbound, run **on mail3**

```bash
# Raw TCP reachability to a real MX
timeout 8 bash -c 'exec 3<>/dev/tcp/gmail-smtp-in.l.google.com/25' && echo "OUTBOUND 25: OPEN" || echo "OUTBOUND 25: BLOCKED"

# Two more, in case one destination is the problem rather than the port
timeout 8 bash -c 'exec 3<>/dev/tcp/mx1.hotmail.com/25'     && echo "microsoft OK"
timeout 8 bash -c 'exec 3<>/dev/tcp/mx01.mail.icloud.com/25' && echo "icloud OK"

# Does a real SMTP banner come back, or does something intercept it?
timeout 10 bash -c 'exec 3<>/dev/tcp/gmail-smtp-in.l.google.com/25; head -1 <&3'
# expect a line starting: 220 mx.google.com ESMTP
```

That last one matters. Some ISPs don't block 25 — they **transparently redirect** it to their own filtering relay. If the banner names Frontier rather than Google, your packets are being intercepted, which is worse than a clean block because it looks like it works.

## Inbound, run **from an external host** (mail1 or mail2, or any VPS elsewhere)

```bash
timeout 8 bash -c 'exec 3<>/dev/tcp/47.190.50.190/25' && echo "INBOUND 25: OPEN" || echo "INBOUND 25: BLOCKED"

# Banner check — proves Stalwart answered, not just that the port opened
timeout 10 bash -c 'exec 3<>/dev/tcp/47.190.50.190/25; head -1 <&3'

# Full transaction test
swaks --to postmaster@rannagharplano.com --server 47.190.50.190 --port 25
```

**Do not run the inbound test from inside your own network.** Many routers hairpin correctly and will tell you the port is open when the internet cannot reach it.

## Can Frontier allow inbound 25 while refusing a custom PTR?

**Yes — and this is the most likely outcome.** They are completely unrelated systems:

| | Inbound TCP 25 | Custom PTR |
|---|---|---|
| What it is | a packet-filtering rule on their network edge | a DNS record in a zone their nameservers serve |
| Who handles it | network operations / provisioning | DNS administration, often a different team or a manual process |
| Typical business-plan default | usually open (that's much of what you pay for) | often "not offered" or "submit a ticket per address" |

So expect: inbound 25 works, outbound 25 works, PTR is a fight. That combination is exactly **Configuration B plus a working inbound path** — which still means mail3 does not send directly, because §9 row B is about reputation, not connectivity. Port 25 being open is necessary but not sufficient.

---

# 11. Checking all three PTRs

Run these from anywhere. **Note the Singapore IP — I have used `172.104.58.45` per your correction, not the `102.` in your item 11.**

```bash
# --- Reverse: IP -> name ---
dig +short -x 172.104.58.45
dig +short -x 104.237.138.198
dig +short -x 47.190.50.190

# --- Forward: name -> IP ---
dig +short mail1.rannagharplano.com
dig +short mail2.rannagharplano.com
dig +short mail3.rannagharplano.com

# --- The endpoints ---
dig +short mail.rannagharplano.com
dig +short webmail.rannagharplano.com
dig +short db.rannagharplano.com
```

## Expected results

| Command | Expected | Meaning if wrong |
|---|---|---|
| `dig +short -x 172.104.58.45` | `mail1.rannagharplano.com.` | Set it in the Linode console. Until then mail1 must not send |
| `dig +short -x 104.237.138.198` | `mail2.rannagharplano.com.` | Same. **This is your primary sender — it is not optional** |
| `dig +short -x 47.190.50.190` | **Config A:** `mail3.rannagharplano.com.`<br>**Config B:** `47-190-50-190.…ip.frontiernet.net.` | Config B is acceptable *because mail3 doesn't send* |
| `dig +short mail1.…` | `172.104.58.45` | |
| `dig +short mail2.…` | `104.237.138.198` | |
| `dig +short mail3.…` | `47.190.50.190` | |
| `dig +short mail.…` | `104.237.138.198` | must equal mail2 |
| `dig +short webmail.…` | `104.237.138.198` | must equal mail2 |
| `dig +short db.…` | `104.237.138.198` | must equal the DB primary |

## The one-liner that actually proves it

Forward and reverse matching is called **FCrDNS**, and it's what receivers check. Test the round trip, not the two halves:

```bash
for ip in 172.104.58.45 104.237.138.198 47.190.50.190; do
  ptr=$(dig +short -x "$ip" | head -1)
  fwd=$(dig +short "${ptr%.}" | head -1)
  if [ "$fwd" = "$ip" ]; then
    echo "PASS  $ip  <->  ${ptr%.}"
  else
    echo "FAIL  $ip  ->  ${ptr%.}  ->  ${fwd:-NXDOMAIN}"
  fi
done
```

**Every IP that sends directly to the internet must PASS.** In Configuration B, mail3 will report `PASS` against Frontier's generic name (the chain closes — it just closes on the wrong name), so read the actual hostname, don't just trust PASS/FAIL. That is precisely why mail3 relays: the chain being intact is not the same as the name being yours.

---

# 12. The architecture, redrawn with webmail

```
                                  INTERNET
                                      │
        ┌─────────────────────────────┼─────────────────────────────┐
        │                             │                             │
   MX 20│                        MX 10│                             │ no MX
  SMTP  │                    SMTP 25  │  HTTPS 443                  │ (§8.3)
   25   │                    SMTPS 465│  webmail + mail             │
        │                    IMAPS 993│                             │
┌───────▼───────────┐   ┌─────────────▼──────────────┐   ┌──────────▼────────┐
│ mail1             │   │ mail2                      │   │ mail3             │
│ Singapore·Linode  │   │ USA · Linode               │   │ On-prem · Frontier│
│ 172.104.58.45     │   │ 104.237.138.198            │   │ 47.190.50.190     │
│                   │   │                            │   │                   │
│                   │   │  ┌──────────────────────┐  │   │                   │
│                   │   │  │ nginx  :80  :443     │  │   │                   │
│                   │   │  │ stream + ssl_preread │  │   │                   │
│                   │   │  │  routes by SNI:      │  │   │                   │
│                   │   │  │   webmail.* ─┐       │  │   │                   │
│                   │   │  │   everything─┼──┐    │  │   │                   │
│                   │   │  └──────────────┼──┼────┘  │   │                   │
│                   │   │                 │  │       │   │                   │
│                   │   │   ┌─────────────▼┐ │       │   │                   │
│                   │   │   │ Roundcube    │ │       │   │                   │
│                   │   │   │ 1.7.x + PHP  │ │       │   │                   │
│                   │   │   │ :10444 TLS   │ │       │   │                   │
│                   │   │   └──────┬───────┘ │       │   │                   │
│                   │   │          │IMAP 993 │       │   │                   │
│                   │   │          │SMTP 465 │PROXY  │   │                   │
│ ┌───────────────┐ │   │  ┌───────▼─────────▼────┐  │   │ ┌───────────────┐ │
│ │ Stalwart      │ │   │  │ Stalwart :10443 +    │  │   │ │ Stalwart      │ │
│ │ MX / relay    │◄┼───┼──┤ 25 465 993 direct    │──┼───┼►│ IMAP/JMAP LAN │ │
│ │               │ │Zenoh │ ★ singleton tasks    │  │Zenoh │ relay→mail2   │ │
│ └───────┬───────┘ │7447│  └──────────┬───────────┘ │7447│ └───────┬───────┘ │
│         │         │   │             │             │   │         │         │
│ ┌───────▼───────┐ │   │  ┌──────────▼───────────┐ │   │ ┌───────▼───────┐ │
│ │ Garage        │◄┼───┼──┤ Garage               │─┼───┼─►│ Garage        │ │
│ │ zone sg       │ │RPC│  │ zone us-dallas       │ │RPC│ │ zone onprem-tx│ │
│ └───────────────┘ │3901│ └──────────────────────┘ │3901│ └───────────────┘ │
│                   │   │                            │   │                   │
│ ┌───────────────┐ │   │  ┌──────────────────────┐  │   │ ┌───────────────┐ │
│ │ PostgreSQL    │◄┼─WAL──┤ PostgreSQL ★PRIMARY★ │──┼WAL┼►│ PostgreSQL    │ │
│ │ hot standby   │ │   │  │ • stalwart  (mail)   │  │   │ │ hot standby   │ │
│ │               │ │   │  │ • roundcube (prefs)  │  │   │ │               │ │
│ └───────────────┘ │   │  └──────────────────────┘  │   │ └───────────────┘ │
└───────────────────┘   └────────────────────────────┘   └───────────────────┘

          ── Garage: 3 replicas, one per zone, no consensus, WAN-tolerant
          ── PostgreSQL: ONE writable primary, 2 async standbys
          ── Stalwart: active-active, stateless, shares the one data store
          ── Webmail: stateless front end. Stores NO messages.
```

## Where webmail sits, in words

```
Users → https://webmail.rannagharplano.com   (nginx, TLS, mail2)
          │
          └─► Roundcube (PHP)
                │
                ├── IMAP  ssl://mail.rannagharplano.com:993 ──┐
                └── SMTP  ssl://mail.rannagharplano.com:465 ──┤
                                                              ▼
                                                    Stalwart cluster
                                                              │
                                             ┌────────────────┴───────────────┐
                                             ▼                                ▼
                                  PostgreSQL primary                 Garage 3-node S3
                                  (metadata, prefs)               (message bodies ×3)
```

**Roundcube is a client.** It holds no messages. Every message it displays is fetched from Stalwart over IMAP at request time, and Stalwart fetches the body from Garage. If you deleted the entire Roundcube installation, not one byte of mail would be lost.

## Why nginx uses SNI passthrough rather than terminating everything

This is the design detail that makes webmail coexist with Stalwart on one IP and one port, and it is Stalwart's own documented pattern.

nginx's `stream` module listens on 443, reads the **SNI** field of the TLS handshake without decrypting anything, and forwards the raw connection:

```nginx
stream {
    map $ssl_preread_server_name $https_backend {
        webmail.rannagharplano.com  127.0.0.1:10444;   # nginx's own TLS vhost → PHP
        default                     127.0.0.1:10443;   # Stalwart, terminates its own TLS
    }
    server {
        listen 443;
        listen [::]:443;
        ssl_preread on;
        proxy_pass  $https_backend;
        proxy_protocol on;
    }
}
```

Why this and not ordinary HTTP proxying:

1. **Stalwart keeps its own certificate and its own ACME.** Nothing about your existing TLS design changes. Certificates stay in the shared data store and keep distributing to all three nodes.
2. **JMAP, WebDAV and EventSource pass through untouched.** No buffering, chunked-transfer or WebSocket-upgrade surprises from an HTTP proxy in the middle.
3. **Real client IPs are preserved** via PROXY protocol, so Stalwart's auto-ban still sees the actual attacker. Stalwart's docs are explicit: *"the TLS connection to Stalwart remains untouched and the original client IP is preserved through the Proxy Protocol."*
4. **Ports 25, 465 and 993 don't go through nginx at all** — Stalwart binds them directly. Less to break.

Two things this requires, both flagged now rather than mid-install:

- **Stalwart config change:** move the HTTPS listener to `127.0.0.1:10443` and set `proxyTrustedNetworks` to include `127.0.0.0/8` (SystemSettings → Settings › Network › Services), or `overrideProxyTrustedNetworks` on that listener. Stalwart supports PROXY protocol v1 and v2. Its docs warn: *"Configure the Proxy Protocol on both the proxy and Stalwart. A mismatch… will break connections silently."* We configure both.
- **nginx must have the stream module**, which on Ubuntu means the `libnginx-mod-stream` package. Verify before relying on it:
  ```bash
  apt-get install -y nginx libnginx-mod-stream
  ls /usr/lib/nginx/modules/ | grep -i stream
  nginx -V 2>&1 | tr ' ' '\n' | grep -i -- --with-stream
  ```
  If `ssl_preread` is unavailable in your build, the fallback is **HAProxy**, which does SNI routing natively and is also documented by Stalwart. I'll include both configs in the deployment scripts so you aren't stuck either way.

---

# 13. Webmail storage — exactly what lives where

## Does Roundcube need its own database? **Yes — a small one.**

| | |
|---|---|
| Database | **PostgreSQL**, a separate database named `roundcube` with its own role, on the existing primary (mail2) |
| Why not SQLite | SQLite would work at your scale and be simpler. PostgreSQL wins because it is **already backed up by your existing job**, and because it **follows a failover automatically** — promote mail3, and every user's preferences and contacts are already there. A SQLite file would be stranded on the dead node |
| Why not its own server | Absolutely not. That would be exactly the "second independent system" you said you don't want |
| Isolation | Separate database, separate role, no permissions on the `stalwart` database. A Roundcube SQL injection cannot reach your mail metadata |

## What is stored, and where — the complete picture

| Data | Stored where | Size | Notes |
|---|---|---|---|
| **Email messages** | **Garage S3 (bodies) + PostgreSQL `stalwart` (metadata)** | your mailbox quotas | ✅ **Never in Roundcube.** Fetched over IMAP at request time |
| **Attachments** | **Garage S3**, as part of the message | — | ✅ Never in Roundcube's database. Transiently in `/var/lib/roundcube/temp` while composing or previewing, deleted by Roundcube's own cleanup |
| **Message cache** | **Nowhere — disabled** | 0 | `$config['messages_cache'] = false;`. This is the setting that makes your requirement 7 true. Left on, Roundcube caches message *bodies* in SQL, which would be a genuine second mail store |
| **IMAP index cache** | PostgreSQL `roundcube` | a few MB | `$config['imap_cache'] = 'db';` — folder listings, UID maps, thread indexes. **Metadata only, no message content.** Keeping this makes the UI noticeably faster. If you'd rather have zero cache, set it to `null` |
| **Sessions** | PostgreSQL `roundcube`, table `session` | KB, auto-expired | `$config['session_storage'] = 'db';`. **No Redis needed** — see §14 |
| **Contacts** | PostgreSQL `roundcube`, tables `contacts` / `contactgroups` | KB per user | Default. **Optional better answer:** the third-party `carddav` plugin points Roundcube at Stalwart's native CardDAV, so contacts live in Stalwart and sync with phones. Adds a third-party plugin to maintain — start without it |
| **Preferences** (skin, signature, filters UI state) | PostgreSQL `roundcube`, table `users` | KB per user | |
| **Sieve filters** | **Stalwart**, via ManageSieve | — | ✅ Filters live in Stalwart, not Roundcube. Requires re-enabling ManageSieve **bound to 127.0.0.1:4190 only** |
| **Roundcube application code** | `/var/www/roundcube` | ~150 MB | |
| **Logs** | `/var/log/roundcube` | rotated | |

## Total disk cost

| Item | Size |
|---|---|
| Roundcube code + assets | ~150 MB |
| PHP 8.3 + FPM + extensions | ~120 MB |
| nginx | ~10 MB |
| `roundcube` PostgreSQL database (10 users, cache on, messages_cache off) | **~20–50 MB** |
| Temp/attachment scratch | ~200 MB peak |
| **Total** | **≈ 600 MB, call it 1 GB with headroom** |

**On a 50 GB disk that is 2%.** Webmail is not what threatens your storage budget — §16.2 explains what actually does.

---

# 14. Webmail security

| Requirement | How | Setting |
|---|---|---|
| **HTTPS only** | HSTS + permanent redirect from 80 | `add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;` and `return 301 https://$host$request_uri;` on :80 |
| **Secure cookies** | | `$config['session_samesite'] = 'Strict';` plus nginx `fastcgi_param PHP_VALUE "session.cookie_secure=1 \n session.cookie_httponly=1"` |
| **CSRF protection** | Built in — Roundcube signs every request with a per-session token | `$config['use_secure_urls'] = true;` Do not disable request tokens |
| **Rate limiting** | nginx on the login endpoint | `limit_req_zone $binary_remote_addr zone=rcmlogin:10m rate=10r/m;` applied to the login POST |
| **Brute-force protection** | Roundcube's own delay + the nginx limit above | `$config['login_rate_limit'] = 3;` and `$config['failed_login_delay'] = 5;` |
| **Secure sessions** | DB-backed, short lifetime, IP-checked | `$config['session_lifetime'] = 30;` (minutes), `$config['ip_check'] = true;`, `$config['referer_check'] = true;` |
| **No plaintext IMAP** | `ssl://…:993` only; port 143 stays disabled on every listener | |
| **No plaintext SMTP auth** | `ssl://…:465` only; 587 stays closed | Implicit TLS, so credentials never traverse an unencrypted phase |
| **Security updates** | `unattended-upgrades` for PHP/nginx (OS packages) + a scripted Roundcube updater + a monitor that alerts when a new release appears | Roundcube itself is a tarball, not an apt package — **it will not auto-update, and pretending otherwise is how webmail servers get owned.** The deploy scripts will include an update command and a version check for your monitoring |
| **Admin surface** | Delete `installer/` after setup | `rm -rf /var/www/roundcube/installer` — Roundcube refuses to run in production while it exists, but delete it anyway |
| **Data directories** | `config/`, `logs/`, `temp/` outside the web root or denied by nginx | `location ~ ^/(config|temp|logs)/ { deny all; }` |

## Do you need Redis? **No.**

Roundcube can use Redis or Memcached for sessions and caching. **You do not need it.** PHP's database session handler is fine for your user count, it keeps sessions in a store that is already replicated and backed up, and it means one less daemon holding one less port. Adding Redis here would be exactly the unnecessary infrastructure you asked me to avoid.

*(Note: this is separate from Stalwart's optional Redis in-memory store, which we also skipped.)*

## ⚠️ The auto-ban trap — this one is not obvious and it will bite you

Roundcube connects to IMAP **from mail2**, so from Stalwart's point of view every webmail login — including every failed one — originates at `104.237.138.198`, not at the user's real address.

Left alone, this is actively dangerous: an attacker hammering the webmail login form triggers Stalwart's auto-ban, which bans **mail2's own IP**, which cuts off webmail for every legitimate user. The attacker gets a denial of service for free.

The fix, in two parts:

1. **Allowlist mail2's own IP in Stalwart's auto-ban** (Settings → Server → Auto-Ban → allowlist: `104.237.138.198/32`, plus `127.0.0.0/8`).
2. **Accept that webmail brute-force protection therefore lives at the webmail tier**, not in Stalwart — which is why the nginx `limit_req` and Roundcube's `login_rate_limit` in the table above are not optional extras. They are the only thing standing between an attacker and unlimited password guesses through the web form.

Direct IMAP/SMTP/JMAP clients are unaffected — Stalwart sees their real IPs and bans them normally.

## Password reset — a gap you should know about

There is **no self-service forgotten-password flow** in this design.

- **Change a known password:** the user goes to `https://mail.rannagharplano.com/account` (Stalwart's Account Manager), which also handles 2FA and app passwords. Roundcube's `password` plugin stays **disabled** — it has no Stalwart driver, and pointing users at the Account Manager is both simpler and safer.
- **Forgotten password:** an administrator resets it in `/admin`. There is no email-a-reset-link flow, because the reset link would go to the mailbox they can't reach.

For a small organisation this is normal and arguably safer. Just make sure **more than one person** can reach the admin console, or a single locked-out admin becomes a locked-out organisation. That is what the second break-glass admin account is for.

---

# 15. Webmail TLS

**Webmail gets its own certificate. Do not add `webmail.rannagharplano.com` to the Stalwart SAN certificate.**

The reason is mechanical: nginx terminates the TLS session for `webmail.`, and Stalwart terminates it for everything else. Stalwart's certificates live inside its data store, and there is no documented way to export them to a file for nginx to read. Two terminators, two certificates.

| | Stalwart's certificate | Webmail's certificate |
|---|---|---|
| Issued by | Stalwart's built-in ACME | certbot |
| Challenge | **DNS-01** — required, because the validating node is not the node each name resolves to | **HTTP-01** — works fine, because `webmail.` resolves to exactly the host that serves it, and nginx owns port 80 |
| Names | `mail`, `mail1`, `mail2`, `mail3`, `autoconfig`, `autodiscover`, `mta-sts`, apex | `webmail.rannagharplano.com` only |
| Stored | in the shared PostgreSQL data store, distributed to all three nodes | `/etc/letsencrypt/live/webmail.rannagharplano.com/` on mail2 |
| Renewal | Stalwart's `taskScheduler` cluster task | `certbot.timer`, with `--deploy-hook "systemctl reload nginx"` |
| Used by | SMTP 25, SMTPS 465, IMAPS 993, and HTTPS via the nginx passthrough | the nginx `:10444` vhost |

This is genuinely simpler than trying to unify them, and each mechanism is the natural fit for its job. It also means a webmail certificate failure cannot take down SMTP, and vice versa.

Issue it with:

```bash
certbot certonly --webroot -w /var/www/certbot \
  -d webmail.rannagharplano.com \
  --agree-tos -m postmaster@rannagharplano.com --non-interactive
```

Verify afterwards that SNI routing sends each name to the right terminator:

```bash
echo | openssl s_client -connect 104.237.138.198:443 -servername webmail.rannagharplano.com 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName
# expect: CN/SAN = webmail.rannagharplano.com only

echo | openssl s_client -connect 104.237.138.198:443 -servername mail.rannagharplano.com    2>/dev/null | openssl x509 -noout -subject -ext subjectAltName
# expect: the multi-name Stalwart SAN certificate
```

---

# 16. Full architecture review

## 16.1 Every item on your list

| Area | Status | Notes / what changed |
|---|---|---|
| **Webmail** | ✅ Added | Roundcube 1.7.x on mail2, §1–§4, §13–§15 |
| **PTR / rDNS** | ⚠️ **Open** | Frontier request pending. Configuration B is the safe default until they answer. §5 |
| **Port 25 outbound** | ⚠️ **Open** | Linode ticket for both Linodes; Frontier test for mail3. §10 |
| **Port 25 inbound** | ⚠️ **Open** | Must be tested from outside your network. §10 |
| **SMTP reputation** | ⚠️ Managed | Two cold IPs to warm. mail3 excluded from sending. Warm-up plan in the runbook |
| **SPF** | ✅ | Two versions, §8. `-all`, literal `ip4:` terms (no DNS-lookup budget consumed) |
| **DKIM** | ✅ | Ed25519 + RSA-2048 dual keys, date-based selectors, generated by Stalwart |
| **DMARC** | ✅ | `p=none` → `quarantine` → `reject` over ~5 weeks. `dmarc-reports@` must exist first |
| **MTA-STS** | ✅ | TXT + policy file served by Stalwart over HTTPS |
| **TLS-RPT** | ✅ | `tls-reports@` must exist |
| **CAA** | ✅ | Let's Encrypt only, plus `iodef` |
| **DNSSEC** | ⚠️ Recommended, not required | Enable at your DNS host + registrar (DS record). **Required before you publish TLSA/DANE records.** Without DNSSEC, DANE is meaningless; with a wrong TLSA record, DANE-aware senders refuse delivery. Order: DNSSEC → prove renewals → `3 1 1` TLSA |
| **ACME** | ✅ | Two mechanisms, §15. DNS-01 for Stalwart, HTTP-01 for webmail |
| **Autodiscover / autoconfig** | ✅ | CNAMEs + SRV, all pointing at `mail.`, served by Stalwart |
| **IMAP** | ✅ | 993 implicit TLS only. 143 disabled everywhere |
| **SMTP submission** | ✅ | 465 only. 587 stays closed — §4 |
| **JMAP** | ✅ | 443 via the nginx SNI passthrough, unmodified |
| **PostgreSQL failover** | ⚠️ Manual by design | ~2 min. Target chosen by measured latency. **Now includes a webmail step** — §2 |
| **Garage replication** | ✅ | RF 3, one zone per site, `consistent` mode |
| **Garage disk usage** | 🔴 **Changed — see 16.2** | Your capacity number comes down unless you add disk |
| **Backup** | ✅ Extended | Now also covers the `roundcube` database (same `pg_dump` job) and `/var/www/roundcube/config` |
| **Restore** | ✅ | Quarterly rehearsal on a throwaway VM. Untested backups don't count |
| **Monitoring** | ✅ Extended | Add: webmail HTTPS reachability, webmail certificate expiry, **Roundcube version vs latest release** |
| **Alerting** | ✅ | Thresholds in the runbook. The DB-primary alert is the one that matters most, because it is your manual-failover trigger |
| **Node failure** | ✅ | §9 of the runbook, TESTs 1, 1b, 1c |
| **WAN latency** | ✅ | No consensus system spans the WAN. Garage tolerates it by design; PostgreSQL has one primary |
| **Split brain** | ✅ **Structurally impossible** | One writable database. An isolated node is inert, not divergent |
| **Cluster recovery** | ✅ | Garage resyncs automatically; `garage repair`, `skip-dead-nodes` documented |
| **Database recovery** | ✅ | Promote + rebuild-as-standby, both directions |
| **Webmail failure** | ✅ **New** | Webmail down but mail up → users fall back to IMAP clients and JMAP; nothing is lost. Rebuild is a 3-minute reinstall — it holds no unique state |
| **Password reset** | ⚠️ **Gap, documented** | No self-service forgotten-password flow. §14 |
| **Admin access** | ✅ | TOTP mandatory; two admins; admins have no mailbox access; `/admin` behind the SNI passthrough |
| **Spam protection** | ✅ | Stalwart's classifier + DNSBLs + greylisting. Training pinned to one node |
| **Outbound rate limits** | ✅ | Per-user caps — the blast radius when a user's password is phished |
| **Abuse prevention** | ✅ | No open relay (tested explicitly), auth required for submission, per-user quotas |
| **IP reputation** | ⚠️ Ongoing | External blacklist monitoring on both sending IPs. mail3 excluded from sending |
| **IPv6** | ⚠️ **Recommend: don't, yet** | See below |

**On IPv6:** publish AAAA records only when IPv6 works end-to-end **and** you have IPv6 PTR records for the sending addresses. A host with an AAAA record and broken IPv6 mail is worse than one with no AAAA at all — senders prefer IPv6, fail, and defer for days. Linode gives each instance a `/128`; Frontier business typically delegates a `/56` by DHCPv6-PD, but the prefix can change and Frontier's IPv6 rDNS story is likely to be worse than its IPv4 one. **Recommendation: v4-only for mail. Revisit once IPv4 rDNS is settled.**

## 16.2 Is 50 GB per node still enough? — **Yes, but your Garage number has to come down**

Webmail is not the problem. **My previous storage table was the problem** — it added up to ~51 GB on a 50 GB disk before webmail existed, and I should have caught it.

Honest recomputation for **mail2**, the heaviest node (DB primary + webmail + Garage + Stalwart):

| Item | Size | Note |
|---|---|---|
| OS + packages | 6 GB | Ubuntu 24.04 minimal ≈ 4 GB plus upgrade headroom |
| **Garage data** | **20 GB** | ↓ from 24 GB |
| **Garage metadata** | 3 GB | LMDB |
| **Garage snapshots** | 2 GB | 6-hourly auto-snapshots |
| PostgreSQL (`stalwart` + `roundcube`) | 6 GB | Metadata only — bodies are in Garage |
| Stalwart local state | 1 GB | |
| **Webmail stack** | **1 GB** | 🆕 nginx + PHP 8.3 + Roundcube + temp |
| Logs + journal | 2 GB | journald capped at 1 GB |
| Backup staging | 3 GB | |
| **Free reserve** | **6 GB** | Non-negotiable. A full disk corrupts LMDB and stops PostgreSQL writes |
| **Total** | **50 GB** | |

**Consequences you need to accept or fix:**

| | |
|---|---|
| Garage declared capacity | **18G per node** (down from 25G), inside a 20 GB data reservation |
| **Usable, 3×-replicated S3** | **≈ 18 GB** — remember: usable == *one* node's capacity, not the sum |
| Bucket hard quota | **15 GiB** (down from 20 GiB) |
| Your original target | ~30 GB |

**You cannot get 30 GB of usable S3 out of 50 GB per node.** 30 GB usable needs 30 GB of Garage data on every node, and once you add the OS, PostgreSQL, Stalwart, webmail, logs and a safety reserve, there isn't 30 GB left. This was true before webmail and I under-stated it.

### The fix, if you want your 30 GB

Attach a **Linode Block Storage volume** to each Linode and mount it at `/var/lib/garage`:

| Setup | Garage capacity/node | Usable S3 | Notes |
|---|---|---|---|
| No change | 18G | **~18 GB** | Works. Tight. Alert at 75% |
| **+50 GB volume per node** | 40G | **~40 GB** | ✅ Recommended. Beats your 30 GB target, and the root disk suddenly has 25 GB free |
| +30 GB volume per node | 25G | ~25 GB | Meets the previous plan's number |

On mail3 this is just a second virtual disk on your VM — free. On the Linodes it's a few dollars a month each. Given that Garage metadata corruption on a full disk is one of the nastier failure modes here, **I'd take the volumes.**

Whichever you choose, it is one line in `.env` (`GARAGE_CAPACITY`) plus a mount point — decided now, before install, which is exactly the point of this document.

## 16.3 Things not on your list that I'd still flag

1. **`dmarc-reports@` and `tls-reports@` must exist before you publish the records that point at them.** Otherwise every report bounces, and the bounces come from you.
2. **Let's Encrypt rate limits during setup**: 5 failed validations per hour. Use `https://acme-staging-v02.api.letsencrypt.org/directory` while you get DNS-01 working, then switch.
3. **Roundcube will not auto-update.** It is a tarball. Put its version in your monitoring, or you will be running a known-vulnerable webmail in eight months without noticing.
4. **ManageSieve must be re-enabled on `127.0.0.1:4190`** for Roundcube's filter UI. It stays closed to the internet.
5. **Two admins with TOTP, from day one.** With no self-service password reset, one locked-out admin is an outage.
6. **You have 61 IPs and are using one.** Once mail3 sends (Configuration A), consider a second address as a dedicated outbound sender so a blocklisting can't take down inbound and webmail with it.
7. **Test the open-relay check on every node that listens on 25**, not just mail2. It is the one misconfiguration that is unrecoverable in reputation terms.

---

# 17. Prerequisites and sign-off

## Blocking — I need answers before writing the deployment scripts

| # | Question | Why it blocks |
|---|---|---|
| **1** | **Is the Singapore IP `172.104.58.45` or `102.104.58.45`?** | Every firewall rule, SPF record, `pg_hba` line and Garage peer entry |
| **2** | **What is the exact CIDR of your Frontier /26?** (e.g. `47.190.50.128/26`) | Needed verbatim in the RFC 2317 request. Don't guess it — read it from your Frontier config or router WAN settings |
| **3** | **Block storage: yes or no?** Adding ~50 GB per node gets you ~40 GB usable S3 and real headroom. Without it, `GARAGE_CAPACITY=18G` | Sets `GARAGE_CAPACITY` and the mount layout, which must be right before Garage's layout is applied — changing it later means a cluster rebalance |
| **4** | **Confirm: MX 10 + MX 20 only, no MX 30?** (§8.3) | Shapes the DNS plan and mail3's listener config |

## Non-blocking, but do them now — they have long lead times

- [ ] **Linode ticket: unblock outbound TCP 25** on both Linodes (days)
- [ ] **Linode: set PTR** for both Linode IPs (minutes, but needs forward DNS live first)
- [ ] **Frontier ticket: PTR request** (§5, Request 1) — days to weeks
- [ ] **Test inbound and outbound port 25 on mail3** (§10) — 5 minutes, do it today
- [ ] **Measure `ping` mail2 → mail3 and mail2 → mail1** — decides your DB failover target
- [ ] **DNS provider API token**, scoped to this zone only, for Stalwart's DNS-01
- [ ] **Publish the A records** and let them propagate
- [ ] **Router: forward TCP 3901 and 7447** to the mail3 VM (and 443 if you want LAN-external IMAP/JMAP there)
- [ ] Confirm all three nodes are Ubuntu 24.04 x86_64 with ≥2 GB RAM

## What you'll get once you answer

1. Updated `RUNBOOK.md` — architecture, DNS Configurations A and B, revised ports and storage tables, webmail sections, updated failure tests
2. Updated `.env` with `MAIL3_PUBLIC_MX`, `MAIL3_RELAY_*`, `WEBMAIL_*`, revised `GARAGE_CAPACITY`
3. `deploy.sh webmail` — nginx + stream/SNI config, PHP 8.3-FPM, Roundcube 1.7.x, the `roundcube` PostgreSQL database and role, certbot, and the full hardened `config.inc.php` generated from `.env`
4. `deploy.sh stalwart` updated for the `127.0.0.1:10443` listener and `proxyTrustedNetworks`
5. HAProxy alternative config, in case `ssl_preread` isn't in your nginx build
6. `bin/verify.sh` extended with webmail, SNI-routing and certificate checks
7. `bin/update-webmail.sh` — the Roundcube upgrade path

**Nothing gets installed until you've answered the four blocking questions.**
