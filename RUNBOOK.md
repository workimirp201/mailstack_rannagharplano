# Stalwart + Garage — 3-node production deployment runbook
### rannagharplano.com · Singapore / USA / on-prem

| Item | Value | Verified against |
|---|---|---|
| Stalwart Mail Server | **v0.16.19** (released 24 Aug 2026) | `stalw.art/docs` (current), GitHub releases |
| Garage | **v2.4.0** (released 6 Sep 2026) | `garagehq.deuxfleurs.fr/documentation`, git.deuxfleurs.fr releases |
| PostgreSQL | **16** (Ubuntu 24.04 default) | Ubuntu 24.04 LTS archive |
| OS | Ubuntu 24.04 LTS, x86_64 | — |
| Document date | 8 September 2026 | — |

> ## ⚠️ SUPERSEDED IN PLACES — read `ARCHITECTURE-REVISION-3.md` first
>
> This runbook is revision 2. Revision 3 added **automated PostgreSQL failover**
> (etcd + Patroni + HAProxy) and **Roundcube webmail on all three nodes**.
> Where they conflict, revision 3 wins. Specifically superseded here:
>
> | Part | Superseded by |
> |---|---|
> | PART 2.9 (manual failover) | REVISION-3 §1–§3 — failover is now automatic, ~3.5 min |
> | PART 5 (firewall ports) | REVISION-3 §7 — adds etcd 2379/2380, Patroni 8008; 5432 now to all three |
> | PART 7.1–7.2 (storage) | REVISION-3 §6 — Garage capacity is **18G**, not 25G |
> | PART 8 (PostgreSQL install) | REVISION-3 — `deploy.sh patroni`, not `deploy.sh postgres` |
> | PART 16 TEST 8 (manual promote) | REVISION-3 §9 TESTS A–E |
> | Singapore IP `102.104.58.45` anywhere | **`172.104.58.45`** |
>
> Everything else — DNS records, the GUI walkthrough, DKIM/SPF/DMARC, backups,
> monitoring and troubleshooting — still applies as written.

> **Read this first.** Stalwart's configuration system changed substantially in the 0.16 line. There is no longer a large `config.toml`. There is a tiny `/etc/stalwart/config.json` that contains **only the data store definition**, and everything else — domains, accounts, listeners, TLS, spam rules, cluster coordination — lives as structured objects **inside the database**, edited through the WebUI or `stalwart-cli`. Any tutorial you find showing `[server.listener.smtp]` TOML blocks is describing a version that no longer exists. This runbook is written against the current docs.

> **Uncertainty is marked.** Where I could not confirm something from official documentation, it says so explicitly, with the command to check it on your own box. I have not invented any command.

---

# PART 1 — Architecture

Your proposed diagram had one thing wrong: there is no "database cluster" spanning the three nodes. Stalwart clustering does **not** work by replicating state between mail servers. It works by having every node share **one** data store, plus a lightweight message bus so nodes can invalidate each other's caches and hand off notifications. Here is what is actually being built.

```
                                    INTERNET
                                        │
        ┌───────────────────────────────┼───────────────────────────────┐
        │                               │                               │
   MX 10 │                        MX 20 │                        MX 30 │
        │                               │                               │
┌───────▼────────────┐        ┌─────────▼──────────┐        ┌───────────▼────────┐
│  mail2             │        │  mail1             │        │  mail3             │
│  USA · Linode      │        │  Singapore·Linode  │        │  On-prem · Frontier│
│  104.237.138.198   │        │  172.104.58.45     │        │  47.190.50.190     │
│                    │        │                    │        │  (business, /26)   │
│ ┌────────────────┐ │        │ ┌────────────────┐ │        │ ┌────────────────┐ │
│ │ Stalwart       │ │        │ │ Stalwart       │ │        │ │ Stalwart       │ │
│ │ role: primary  │ │        │ │ role: edge     │ │        │ │ role: edge     │ │
│ │ SMTP IMAP JMAP │ │        │ │ SMTP in + out  │ │        │ │ SMTP in + out  │ │
│ │ + all singleton│ │        │ │ IMAP/JMAP      │ │        │ │ IMAP/JMAP      │ │
│ │   background   │ │        │ │                │ │        │ │ (once PTR +    │ │
│ │   tasks        │ │        │ │                │ │        │ │  port 25 pass) │ │
│ └───────┬────────┘ │        │ └───────┬────────┘ │        │ └───────┬────────┘ │
│         │          │        │         │          │        │         │          │
│ ┌───────▼────────┐ │        │ ┌───────▼────────┐ │        │ ┌───────▼────────┐ │
│ │ Garage node    │◄┼────────┼─┤ Garage node    │◄┼────────┼─┤ Garage node    │ │
│ │ zone us-dallas │ │  RPC   │ │ zone sg-       │ │  RPC   │ │ zone onprem-tx │ │
│ │ cap 25G        │ │  3901  │ │  singapore     │ │  3901  │ │ cap 25G        │ │
│ └────────────────┘ │        │ │ cap 25G        │ │        │ └────────────────┘ │
│                    │        │ └────────────────┘ │        │                    │
│ ┌────────────────┐ │        │ ┌────────────────┐ │        │ ┌────────────────┐ │
│ │ PostgreSQL 16  │─┼───WAL──┼►│ PostgreSQL 16  │ │        │ │ PostgreSQL 16  │ │
│ │ ★ PRIMARY ★    │─┼────────┼─┼────────────────┼─┼──WAL───┼►│ hot standby    │ │
│ │ (the ONE data  │ │        │ │ hot standby    │ │        │ │                │ │
│ │  store)        │ │        │ │ (read-only)    │ │        │ │ (read-only)    │ │
│ └────────────────┘ │        │ └────────────────┘ │        │ └────────────────┘ │
└─────────┬──────────┘        └─────────┬──────────┘        └─────────┬──────────┘
          │                             │                             │
          └──────── Zenoh peer mesh, TCP 7447 (cache invalidation, ───┘
                    IMAP IDLE fan-out, IP bans, ACME cert push)
          │                             │                             │
          └───────── all three Stalwart nodes WRITE to ───────────────┘
                     db.rannagharplano.com:5432  (= mail2)
```

**Three separate systems, three different consistency models, and that is the whole point:**

| Layer | Topology | Survives losing one node? | Why |
|---|---|---|---|
| **Garage S3** (message bodies, attachments, files) | True 3-way replicated, one zone per site, no consensus algorithm | **Yes, fully** — reads and writes continue | Garage is explicitly built for "multi-sites interconnected through regular Internet connections" and uses no Raft |
| **Stalwart** (SMTP/IMAP/JMAP front ends) | Active-active, stateless | **Yes** — any surviving node serves any mailbox | State is not in Stalwart; it is in the data store |
| **PostgreSQL** (mailbox metadata, accounts, settings) | One writable primary + 2 async standbys | **Only if the surviving node is not the primary.** Losing mail2 needs a promote (≈2 min, documented in PART 16 Test 8) | There is no safe way to have a multi-writer SQL database across a 200 ms WAN |

That last row is the honest trade, and **section 2.7 answers "what happens if a node shuts down" directly** — short version: losing mail1 or mail3 costs you nothing at all, losing mail2 costs a two-minute promote and no mail. Everything else in this design is genuinely fault-tolerant. PART 2 explains why every alternative is worse.

---

# PART 2 — Architecture decisions

## 2.1 Database: why NOT FoundationDB

You were right to ask. Stalwart's own documentation calls FoundationDB "the recommended backend for distributed deployments of Stalwart", so following the docs naively lands you on FDB. **For your topology that would be a mistake**, for reasons that come from FoundationDB's documentation, not Stalwart's:

1. **Quorum commits over a 200 ms WAN.** In `triple` redundancy, FDB requires "at least three available machines... to make progress" and commits must be durable on a quorum of transaction logs. With one machine per site, every single write — every message delivered, every IMAP flag set — pays a Singapore↔Dallas round trip. That is roughly 200–230 ms of added latency on operations that should take microseconds.
2. **The 5-second transaction ceiling is a hard wall.** FoundationDB: *"FoundationDB currently does not support transactions running for over five seconds. In particular, after 5 seconds from the first read in a transaction: subsequent reads that go to the database will usually raise a `transaction_too_old` error."* A transaction that must cross the Pacific twice under load does not have much of that 5 seconds left. Under a delivery burst you get `transaction_too_old` storms, and Stalwart surfaces those as delivery failures.
3. **Three machines is FDB's stated minimum, not a comfortable number.** FDB's docs say triple redundancy is *"best for 5+ machines"* and that fault tolerance in triple mode really wants 4 machines. Three is the point at which any single loss halts progress.
4. **FDB's real multi-region design is not what you have.** FDB's supported cross-region story uses *regions* with satellite datacenters and asynchronous replication between them, with a primary region doing the writes. It explicitly recommends *"three coordinators in the main datacenters of each of the two regions, and then... three additional coordinators in a third region"* — nine coordinators. You have three VMs, one of which is on a residential-class connection.
5. **Operational weight.** FDB needs a *different Stalwart binary* (`stalwart-foundationdb-x86_64-unknown-linux-gnu.tar.gz`) plus the FDB client library installed on every host, and Stalwart's docs confirm: *"The FoundationDB client library must be installed on the host before Stalwart can connect."*

**Verdict: FoundationDB is not appropriate for Singapore ↔ USA ↔ on-prem. Do not deploy it.**

## 2.2 What the other options actually give you

| Backend | Cluster-capable per Stalwart docs | Verdict for your topology |
|---|---|---|
| **RocksDB** | Embedded, single-node | **No.** Each node would have its own private database — three unrelated mail servers, exactly the thing you said you don't want |
| **SQLite** | Embedded, single-node | **No.** Same problem, plus worse concurrency |
| **FoundationDB** | Yes, "recommended for distributed" | **No** — see 2.1 |
| **MySQL / MariaDB / Galera** | Listed as an option; Stalwart notes SQL backends "tend to offer lower performance and concurrency than PostgreSQL and FoundationDB". Galera multi-master over a 200 ms WAN certifies every transaction cluster-wide and is a well-known source of WAN instability | **No** |
| **PostgreSQL, single primary + streaming standbys** | Yes — Stalwart's docs call it *"a reliable alternative"* handling *"medium to large deployments when tuned correctly"* | **Yes. This is the design.** |
| S3 / object storage | **Blob store only** — the docs' support matrix marks S3 as ❌ for the data store | Used for blobs, cannot hold metadata |

**Why single-primary Postgres is the right answer and not a cop-out:** the only way to get a genuinely multi-writer database across these three sites is a consensus system, and every consensus system pays the same 200 ms tax on every write while adding split-brain and quorum-loss failure modes. A single primary has *one* failure mode — the primary dies — and that failure mode has a two-minute, well-understood recovery. You are trading an automatic failover you don't have for a system that doesn't wobble. For a mail server with a small user count, that is the correct trade.

## 2.3 Stalwart clustering: what it does and does not do

From the docs, cluster coordination exists to propagate **real-time updates** (so an IMAP IDLE client on mail1 sees a message delivered on mail2), route **push notifications** across nodes, propagate **IP blocks**, and **distribute newly issued ACME TLS certificates** to all nodes. Coordination is *not* data replication.

Consequences you must internalise:

- ✅ A mailbox created on node 1 **is** visible from nodes 2 and 3 — instantly, because there is literally one database. Your requirement is met.
- ✅ Any node can accept SMTP for any user and serve IMAP for any user.
- ❌ A node cannot serve mail while cut off from the data store. An isolated node is a *dead* node, not a *split-brain* node. That is a feature: there is no divergent state to merge back.

Coordination backend: **Zenoh peer-to-peer** — the docs' default, *"a lightweight peer-to-peer mode that requires no central coordinator or dedicated server."* Kafka and NATS are for "very large" and "medium" clusters and would add a service you'd then have to make highly available. Redis coordination would add a single point of failure. For three nodes, Zenoh is correct.

**Cluster features are in the Community edition.** The comparison page lists "Cluster coordination (Zenoh peer-to-peer, Kafka, Redpanda, NATS, Redis)", "Automatic node ID generation", "Outbound MTA cluster role" and "Fault tolerance and high availability" for both editions. Only **read replicas**, **sharded blob/in-memory stores**, **multi-tenancy**, **AI models** and admin dashboards are Enterprise. Nothing in this deployment requires a licence.

## 2.4 Should Stalwart be active-active across all three? — partly

Yes for **SMTP inbound** and for **cluster membership**. No for **where you point your users' mail clients**.

Every Stalwart node queries the same PostgreSQL primary in Dallas. An IMAP session is many small queries. From Singapore, each of those queries costs ~200 ms. mail1 will *work*, and it will feel bad — folder listings measured in seconds.

So:

- **mail2 (USA)** — the node users actually connect to. `mail.rannagharplano.com` resolves here. DB-local, so IMAP/JMAP is fast. **MX 10.**
- **mail3 (on-prem, Texas)** — **MX 30**, full inbound and outbound SMTP, DB standby, Garage replica, and the IMAP/JMAP endpoint for your LAN. If it is in the same metro as mail2 it is also your **preferred database failover target** (see 2.9).
- **mail1 (Singapore)** — **MX 20**, full inbound SMTP and outbound delivery. SMTP is latency-insensitive (200 ms on a queued message is irrelevant), so mail1 does that job perfectly. Also DB standby and Garage replica. Point Asian users' clients here only if you are willing to accept slow IMAP, or move the DB primary to Singapore instead.

This gives you the single logical mail system you asked for, without pretending 200 ms doesn't exist.

## 2.5 Garage: the part of your plan that was already right

Garage is a genuinely good fit and Stalwart's cluster-storage docs recommend it by name: *"GarageHQ: a distributed, lightweight S3-compatible object store built for self-hosting and resiliency."* Garage's own design goals say it is *"made for multi-sites (eg. datacenters, offices, households, etc.) interconnected through regular Internet connections"* and it advertises *"No RAFT slowing you down"* — no consensus algorithm, which is *"particularly useful when nodes are far from one another and talk to one other through standard Internet connections."*

With `replication_factor = 3`, one zone per site, and the default zone redundancy of `maximum`, Garage **always stores the three copies on nodes at different locations**. Losing a whole site leaves two full copies.

Each Stalwart node points at **its own local Garage daemon on `127.0.0.1:3900`**. Garage handles the cross-site replication itself over RPC. Stalwart never makes a WAN S3 call directly.

## 2.6 The on-prem node — now a full mail node, once you verify two things

You have a **Frontier business plan with 61 static IPs** (a /26, minus network/broadcast/gateway) and you believe port 25 is open. That changes mail3 from "storage only" to a **full peer**: MX 30, inbound SMTP, direct outbound delivery, and an IMAP/JMAP endpoint.

But "believe" is not "verified", and getting this wrong damages the reputation of the whole domain rather than just one node. **Two gates, both testable in about five minutes:**

### Gate 1 — reverse DNS

Every large receiver checks that the connecting IP has a PTR record, and that the PTR's forward lookup comes back to the same IP. No PTR, or a generic one like `47-190-50-190.dhcp.frontier.com`, and Gmail/Microsoft will greylist or reject you regardless of perfect SPF and DKIM.

```bash
dig +short -x 47.190.50.190
# want: mail3.rannagharplano.com.
dig +short mail3.rannagharplano.com
# want: 47.190.50.190     (forward and reverse must agree)
```

Frontier controls this, not you. For a /26 they have two options and you should ask for either:
- set the individual PTR for `47.190.50.190` → `mail3.rannagharplano.com`, or
- **delegate** the reverse zone to your nameservers using RFC 2317 classless delegation (`50.190.47.in-addr.arpa` CNAMEs into a zone you host), which is better because you then control all 61.

If Frontier's business support says "we don't do rDNS", mail3 must not send mail. Set `MAIL3_PUBLIC_MX=no` and relay its outbound through mail2.

### Gate 2 — port 25, both directions

```bash
# OUTBOUND, from mail3:
timeout 8 bash -c 'exec 3<>/dev/tcp/gmail-smtp-in.l.google.com/25' && echo "outbound 25 OK"
swaks --to check-auth@verifier.port25.com --from postmaster@rannagharplano.com --server localhost

# INBOUND — must be run from a machine OUTSIDE your network (mail1 or mail2):
timeout 8 bash -c 'exec 3<>/dev/tcp/47.190.50.190/25' && echo "inbound 25 OK"
swaks --to postmaster@rannagharplano.com --server 47.190.50.190 --port 25
```

Outbound working does not imply inbound working — the router forward and any ISP-side inbound filtering are separate. `./deploy.sh preflight` tests outbound and PTR automatically; **inbound you must test from outside.**

### Once both gates pass

Set `MAIL3_PUBLIC_MX=yes` in `.env` on all three nodes, then:
- add `MX 30 mail3.rannagharplano.com.`
- add `ip4:47.190.50.190` to SPF
- enable the SMTP:25 listener on mail3 (PART 13.5)
- set mail3's outbound strategy to direct rather than relay (PART 13.8)

### Warm the IP up

A brand-new sending IP with no history gets throttled even with flawless authentication. For the first two weeks send from mail1/mail2 and let mail3 handle **inbound only**; then start routing a small share of outbound through it. Watch the DMARC reports.

### Using more than one of your 61 IPs

You have room to separate concerns, which is a real advantage over the Linodes:

| Use | Suggestion |
|---|---|
| `47.190.50.190` | mail3 inbound MX + IMAP/JMAP |
| a second IP | **dedicated outbound sender.** If it gets blocklisted, inbound and web access are unaffected. Set `MAIL3_OUTBOUND_IP` in `.env` and add it to SPF |
| a third IP | bulk/notification mail, kept separate from person-to-person mail so a newsletter complaint can't hurt your transactional reputation |

Don't do all of this on day one. One IP, warmed properly, beats three cold ones.

## 2.7 So: if one node shuts down, does mail keep working?

**This is your actual question, so here it is directly.**

**Yes for two of the three nodes, and no for the third — and the third is fixable.**

| Node that dies | Inbound mail | Users' IMAP / JMAP | Outbound mail | Garage S3 | Action needed |
|---|---|---|---|---|---|
| **mail1 (Singapore)** | ✅ Keeps working. Senders skip MX 20 and use MX 10/30 within seconds | ✅ Unaffected | ✅ mail2/mail3 deliver | ✅ 2 of 3 zones = quorum holds | **None.** Fix it when convenient |
| **mail3 (on-prem)** | ✅ Keeps working. Senders skip MX 30 | ✅ Unaffected | ✅ | ✅ | **None** |
| **mail2 (USA)** | ⚠️ Senders connect to mail1/mail3, which return `4xx` and the senders queue and retry — **mail is delayed, not lost** | ❌ **Down** until you promote | ❌ Queued | ✅ Still fine | **Promote a standby.** ~2 minutes, PART 16 TEST 8 |

**Why mail2 is different:** it holds the single writable PostgreSQL primary. Every Stalwart node reads and writes that one database, so when it disappears the other two nodes are running but have nothing to serve. They are not broken and they are not diverging — they are waiting.

**What you do *not* lose when mail2 dies:**
- No mail is lost. Inbound senders retry for days (your queue expiry is 5 days); their retry schedules are typically 15 min → 1 h → 4 h.
- No stored mail is lost. Bodies are in Garage on three nodes; metadata is on two standbys, seconds behind.
- No split-brain. There is exactly one writable database, so there is no divergent state to reconcile later. This is the quiet benefit of not using a multi-master system.

**If a two-minute manual promote is not acceptable to you, read 2.9** — there is a way to automate it, with real trade-offs.

## 2.8 Failure behaviour, full table

| Event | Garage S3 | Mail service | Data loss |
|---|---|---|---|
| mail1 (SG) down | Fine. Reads/writes continue from 2 remaining zones | Fine. Senders use MX 10 / MX 30 | None |
| mail3 (on-prem) down | Fine | Fine. Senders use MX 10 / MX 20 | None |
| **mail2 (USA) down** | Fine | **Down until you promote a standby** (~2 min). Inbound queues at the *sending* servers | Up to the async replication lag — typically well under a second of WAL |
| Network partition isolating one node | That node can't reach quorum locally; the other two keep serving | Isolated node is inert, not divergent | None. No split-brain: one writable database |
| Any **two** nodes down | 1 of 3 zones left → below quorum, reads fail in `consistent` mode | Down | None; recovers when a second zone returns |
| Frontier outage (power/ISP at the office) | Fine, 2 zones remain | Fine, MX 30 skipped | None |
| A whole Linode region fails | Fine | Fine if it's Singapore; promote if it's the USA | None |

## 2.9 Where to fail the database over to — and whether to automate it

### Pick the target by latency, not by geography

Your two standbys are not equivalent. Promotion moves the database to whichever you choose, and **every Stalwart node then pays that node's latency on every query.**

`104.237.138.198` is Linode's US datacenter and `47.190.50.190` is Frontier in Texas. If those are in the same metro, mail2 ↔ mail3 could be 5–20 ms, which makes mail3 an excellent failover target. Singapore is ~200 ms from either and would make the whole system slow for everyone.

**Measure it before you decide.** `./deploy.sh preflight` now prints inter-node RTT, or:

```bash
# from mail2
ping -c 20 47.190.50.190
ping -c 20 172.104.58.45
mtr -rwc 20 47.190.50.190
```

| mail2 ↔ mail3 RTT | Failover target |
|---|---|
| **< 40 ms** | **mail3.** Promote there; users barely notice |
| 40–150 ms | mail3 still, but expect noticeably slower IMAP |
| > 150 ms, or on-prem is unreliable | mail1, and accept the latency until mail2 is rebuilt |

Whichever you choose, promotion is the same procedure (TEST 8) — you just point `db.rannagharplano.com` at a different IP.

**One caveat if mail2 and mail3 are in the same metro:** a regional event (a DFW-wide power or transit problem) could take both out at once. That is an argument for keeping mail1 as the *third* copy and never letting it fall behind — not an argument against using mail3 as the primary failover target.

### Should you automate the promote?

You *can*: Patroni with a 3-node etcd cluster would detect a dead primary and promote automatically in ~30 seconds, with no human awake.

**My recommendation is to run manual for the first few months, then decide.** The reasoning:

- Automatic failover across a WAN fails over when it *shouldn't*. A brief Singapore ↔ Dallas transit blip — routine on the public internet — can look identical to a dead primary. A spurious failover during a network wobble is worse than the outage it was meant to prevent, because now you have a promoted standby, a primary that comes back thinking it's still primary, and a rebuild.
- With mail2 and mail3 in the same metro, etcd quorum survives a Singapore partition cleanly (2 of 3 members remain), which makes automation *safer here than in most WAN setups*. If your measured mail2↔mail3 latency is under 40 ms, automation is genuinely defensible.
- The failure mode you're guarding against is "primary dies at 3 a.m. and nobody notices until morning". You can close most of that gap with **alerting** (PART 18) for a fraction of the complexity — a page when the primary stops answering gets you to a two-minute fix.

So: **set up the alerting first.** If you find yourself woken by it more than once, or you need an unattended SLA, add Patroni then — by that point you will know your real latency and your real failure rate, which is exactly what you need to configure it safely.

---

# PART 3 — Requirements and pre-flight checklist

## 3.1 Before you touch a server

- [ ] **Open a Linode support ticket to unblock outbound TCP 25** on *both* Linodes. New Linode accounts have port 25 blocked by default. Without this, nothing you build can deliver mail. Do this first — it takes hours to days.
- [ ] **Set reverse DNS (PTR)** in the Linode console: `104.237.138.198 → mail2.rannagharplano.com` and `172.104.58.45 → mail1.rannagharplano.com`. Forward DNS must already resolve to those IPs or Linode will refuse to set the PTR.
- [ ] **Ask Frontier business support for reverse DNS on `47.190.50.190` → `mail3.rannagharplano.com`.** Better still, ask them to delegate the reverse zone for your /26 (RFC 2317 classless delegation of `50.190.47.in-addr.arpa`) so you control all 61. Verify with `dig +short -x 47.190.50.190`. **See 2.6 — this is a gate, not a nice-to-have.**
- [ ] **Test inbound TCP 25 to `47.190.50.190` from outside your network** (from mail1 or mail2 once they're up, or any external host). Outbound working does not prove inbound works.
- [ ] **Measure `ping` between mail2 and mail3.** If it's under ~40 ms, mail3 becomes your preferred database failover target (2.9). Write the number down.
- [ ] **Decide your DNS provider** and get an API token. TLS for a cluster needs the DNS-01 ACME challenge (PART 13.4 explains why HTTP-01/TLS-ALPN-01 cannot work here). Stalwart v0.16 supports Cloudflare, Route 53, Google Cloud DNS, OVH, deSEC, DigitalOcean, Bunny, Porkbun, DNSimple, Spaceship, and self-hosted BIND via RFC 2136 (TSIG or SIG(0)).
- [ ] **On the on-prem router**, forward **TCP 25, 443, 3901 and 7447** to the mail3 VM, and give the VM a DHCP reservation or static LAN IP. (Skip 25 and 443 if `MAIL3_PUBLIC_MX=no`.)
- [ ] Root or sudo on all three nodes; SSH key auth; password auth disabled.
- [ ] At least **50 GB disk and 2 GB RAM per node**. Stalwart alone idles at ~100 MB and 1 GB "is generally sufficient" for a small deployment, but you are also running PostgreSQL and Garage on the same box.

## 3.2 Environment verification — run on ALL THREE nodes

```bash
hostnamectl
cat /etc/os-release
uname -a
lsblk
df -h
free -h
timedatectl status
ip -4 addr show
ip route get 1.1.1.1
curl -s https://api.ipify.org; echo
dig +short -x "$(curl -s https://api.ipify.org)"
```

What you want to see:

- `os-release` → `VERSION_ID="24.04"`, `NAME="Ubuntu"`
- `uname -m` → `x86_64` (if it says `aarch64`, change the Garage download URL to the arm64 build)
- `df -h /` → at least ~40 GB available
- `timedatectl status` → `System clock synchronized: yes` and `NTP service: active`
- The `curl ipify` output must match the IP you put in `.env`
- `dig -x` should return your `mailN.rannagharplano.com` once PTR is set

## 3.3 Packages to install

`deploy.sh prep` installs all of these; listed here so you know what and why.

| Package | Why |
|---|---|
| `curl`, `wget` | fetching Garage and the Stalwart installer |
| `ca-certificates` | TLS trust for everything, plus the custom Postgres CA |
| `jq` | parsing Garage/Stalwart JSON output in verification steps |
| `unzip` | occasional archive handling |
| `openssl` | generating secrets, the Postgres CA, and inspecting certificates |
| `dnsutils` (`dig`) | every DNS verification step in PART 15 |
| `systemd-timesyncd` | time sync (see PART 6.3) |
| `python3` | safe in-place `.env` editing by `gen-secrets` |
| `logrotate` | keeps `/var/log` from eating the disk |
| `s3cmd` | S3 verification tests in PART 15/16 |
| `swaks` | SMTP send/receive testing |
| `postgresql-16` | the data store |

**Docker is not installed and not used.** See PART 6.1 for the reasoning.

---

# PART 4 — DNS

Replace TTLs with your provider's minimum where noted. `db.` and `mail.` deliberately have **60-second TTLs** because they are your failover levers.

## 4.1 Host records

```
; ---- A records: one per physical node -------------------------------------
mail1.rannagharplano.com.   300  IN  A      172.104.58.45
mail2.rannagharplano.com.   300  IN  A      104.237.138.198
mail3.rannagharplano.com.   300  IN  A      47.190.50.190

; ---- The single logical client endpoint. Points at ONE node. --------------
; 60s TTL: this is what you repoint during a mail2 outage.
mail.rannagharplano.com.     60  IN  A      104.237.138.198

; ---- The data store endpoint. Points at the Postgres PRIMARY. -------------
; 60s TTL: this is what you repoint when you promote a standby.
db.rannagharplano.com.       60  IN  A      104.237.138.198
```

**AAAA records:** only add them once IPv6 works *and* you have IPv6 PTR records. A host with an AAAA record but broken IPv6 mail is worse than one with no AAAA at all — sending servers prefer IPv6, fail, and defer. Linode gives every instance a /128 (and a routed /64 on request); if you enable it:

```
mail1.rannagharplano.com.   300  IN  AAAA   2400:8901::xxxx:xxxx:xxxx:xxxx
mail2.rannagharplano.com.   300  IN  AAAA   2600:3c00::xxxx:xxxx:xxxx:xxxx
```
…and set the matching IPv6 rDNS in the Linode console, and add `ip6:` terms to SPF. mail3 gets no AAAA. **If in doubt, publish no AAAA records at all** — v4-only mail is completely normal.

## 4.2 MX — and why round-robin is not failover

```
rannagharplano.com.         3600 IN  MX  10  mail2.rannagharplano.com.
rannagharplano.com.         3600 IN  MX  20  mail1.rannagharplano.com.
rannagharplano.com.         3600 IN  MX  30  mail3.rannagharplano.com.
```

**Publish the MX 30 record only after both gates in 2.6 pass** (Frontier PTR set, inbound and outbound 25 verified). Until then, publish only MX 10 and MX 20 — an MX record pointing at a host that can't accept mail costs every sender a connection timeout before they fall through to the next one.

Order: mail2 first because it is DB-local, so a message delivered there needs no WAN round trip. mail3 last because it is the least reliable link (office power and a consumer-grade uplink), not because it is untrusted.

You were right to be suspicious of DNS round-robin. Here is the distinction that matters:

- **For inbound SMTP, MX priorities are real failover, and they are the correct production mechanism.** RFC 5321 requires a sending MTA to try the lowest-preference MX first and, on failure, try the next one. If mail2 is unreachable, every standards-compliant sender on the internet retries mail1 within seconds. There is no DNS change and no propagation delay. This is not round-robin; it is an ordered, protocol-level failover that has worked since 1982.
- **For client access (IMAP/JMAP/submission), DNS round-robin genuinely is not failover.** Round-robin hands a client one of N addresses at random with no health awareness. When one node dies, roughly 1/N of your users get connection timeouts, and their cached DNS keeps sending them back to the dead host for the TTL. Mail clients handle this badly — Outlook in particular will sit in "Trying to connect" rather than trying another address.

  So: **one A record for `mail.rannagharplano.com`, pointing at one node, TTL 60.** Client failover is a deliberate DNS change you make (or automate with a health-checked DNS provider such as Route 53 failover records or Cloudflare load balancing). That is the correct production approach at this scale — a real HA client endpoint needs an anycast VIP or a health-checked global load balancer, which is not something you can build out of three unconnected VMs.

**Never point an MX record at a CNAME.** RFC 2181 forbids it and many MTAs will fail the lookup.

## 4.3 SPF

**Phase 1 — before mail3's gates pass (start here):**

```
rannagharplano.com.         3600 IN  TXT  "v=spf1 ip4:104.237.138.198 ip4:172.104.58.45 -all"
mail1.rannagharplano.com.   3600 IN  TXT  "v=spf1 a -all"
mail2.rannagharplano.com.   3600 IN  TXT  "v=spf1 a -all"
mail3.rannagharplano.com.   3600 IN  TXT  "v=spf1 -all"
```

**Phase 2 — after PTR and port 25 are both verified on mail3:**

```
; Organisational domain — authorise all three senders, nothing else.
rannagharplano.com.         3600 IN  TXT  "v=spf1 ip4:104.237.138.198 ip4:172.104.58.45 ip4:47.190.50.190 -all"

; The HELO/EHLO identities also need SPF, or HELO-based SPF checks fail.
mail1.rannagharplano.com.   3600 IN  TXT  "v=spf1 a -all"
mail2.rannagharplano.com.   3600 IN  TXT  "v=spf1 a -all"
mail3.rannagharplano.com.   3600 IN  TXT  "v=spf1 a -all"
```

`-all` (hard fail), not `~all`. You know exactly which IPs send your mail; say so.

**If you dedicate a separate IP from your /26 to outbound** (2.6), add it too: `ip4:47.190.50.191`. List **only** IPs that actually send. Every extra address in an SPF record is an address an attacker could exploit if it ever changes hands, and SPF is limited to 10 DNS-lookup mechanisms — `ip4:` terms don't count toward that, which is another reason to use literal IPs rather than `a`/`mx`/`include`.

**Do not add mail3 to SPF before its PTR is set.** SPF passing while rDNS is missing is a classic "authenticated but still filtered" state — you'd have done the work and still land in spam.

## 4.4 DKIM

Stalwart generates the keys; you publish what it gives you. Do **not** invent these values — PART 14 shows how to read the real ones out of the WebUI. Stalwart's docs show the modern dual-key form (Ed25519 plus RSA, so that receivers which don't do Ed25519 still get a valid signature):

```
202609e._domainkey.rannagharplano.com.  3600 IN TXT "v=DKIM1; k=ed25519; h=sha256; p=<BASE64 FROM STALWART>"
202609r._domainkey.rannagharplano.com.  3600 IN TXT "v=DKIM1; k=rsa;     h=sha256; p=<BASE64 FROM STALWART>"
```

The selector names (`202609e` / `202609r`) are whatever Stalwart generates — date-based selectors make rotation obvious. RSA keys must be 2048-bit; many DNS UIs need the long `p=` value split into 255-character chunks (`"part1" "part2"`), which most providers do automatically.

## 4.5 DMARC

```
_dmarc.rannagharplano.com.  3600 IN TXT  "v=DMARC1; p=none; rua=mailto:dmarc-reports@rannagharplano.com; ruf=mailto:dmarc-reports@rannagharplano.com; fo=1; adkim=r; aspf=r; pct=100"
```

**Start at `p=none` and mean it.** Publish `p=reject` on day one and any legitimate mail path you forgot — a monitoring alerter, a website contact form, a mailing list — silently vanishes. The progression:

1. **Weeks 1–2:** `p=none`. Read the aggregate reports (Stalwart parses them for you — WebUI → Reports → DMARC).
2. **Weeks 3–4:** once every legitimate source shows DKIM+SPF pass, move to `p=quarantine; pct=25`, then `pct=100`.
3. **Week 5+:** `p=reject`.

Create `dmarc-reports@rannagharplano.com` as a real mailbox before publishing this record.

## 4.6 TLS-related records

```
; --- MTA-STS: forces compliant senders to use verified TLS to reach you ---
mta-sts.rannagharplano.com.       3600 IN CNAME  mail2.rannagharplano.com.
_mta-sts.rannagharplano.com.      3600 IN TXT    "v=STSv1; id=20260908000000"

; --- SMTP TLS Reporting: you get told when someone's TLS to you fails ---
_smtp._tls.rannagharplano.com.    3600 IN TXT    "v=TLSRPTv1; rua=mailto:tls-reports@rannagharplano.com"

; --- CAA: only Let's Encrypt may issue for this domain ---
rannagharplano.com.               3600 IN CAA    0 issue "letsencrypt.org"
rannagharplano.com.               3600 IN CAA    0 issuewild "letsencrypt.org"
rannagharplano.com.               3600 IN CAA    0 iodef "mailto:security@rannagharplano.com"
```

The MTA-STS **policy file** must be served over HTTPS at `https://mta-sts.rannagharplano.com/.well-known/mta-sts.txt`. Stalwart serves this itself once the domain is configured. Bump the `id=` in the TXT record every time you change the policy.

**DANE / TLSA:** Stalwart supports it, and the docs give the record shape:

```
_25._tcp.mail2.rannagharplano.com. 3600 IN TLSA 3 0 1 <sha256-of-cert>
```

**Do not publish TLSA records yet.** DANE requires DNSSEC on the zone, and a TLSA record that doesn't match your current certificate causes DANE-aware senders (which includes a large share of European mail) to *refuse* delivery. Get DNSSEC signed and your renewal automation proven first, then add `3 1 1` (SPKI-based) records, which survive certificate renewal as long as the key is reused.

## 4.7 Client autoconfiguration

```
autoconfig.rannagharplano.com.     3600 IN CNAME  mail.rannagharplano.com.   ; Thunderbird
autodiscover.rannagharplano.com.   3600 IN CNAME  mail.rannagharplano.com.   ; Outlook

_autodiscover._tcp.rannagharplano.com. 3600 IN SRV 0 1 443 mail.rannagharplano.com.
_imaps._tcp.rannagharplano.com.        3600 IN SRV 0 1 993 mail.rannagharplano.com.
_submissions._tcp.rannagharplano.com.  3600 IN SRV 0 1 465 mail.rannagharplano.com.
_jmap._tcp.rannagharplano.com.         3600 IN SRV 0 1 443 mail.rannagharplano.com.

; Actively tell clients NOT to try plaintext ports (RFC 6186 / RFC 8314):
_imap._tcp.rannagharplano.com.         3600 IN SRV 0 0 0 .
_submission._tcp.rannagharplano.com.   3600 IN SRV 0 0 0 .
_pop3._tcp.rannagharplano.com.         3600 IN SRV 0 0 0 .
```

All autoconfiguration points at `mail.` — never at an individual node.

## 4.8 Complete zone summary

| Name | Type | Value | TTL |
|---|---|---|---|
| `mail1` | A | 172.104.58.45 | 300 |
| `mail2` | A | 104.237.138.198 | 300 |
| `mail3` | A | 47.190.50.190 | 300 |
| `mail` | A | 104.237.138.198 | **60** |
| `db` | A | 104.237.138.198 | **60** |
| `@` | MX 10 | mail2.rannagharplano.com. | 3600 |
| `@` | MX 20 | mail1.rannagharplano.com. | 3600 |
| `@` | MX 30 | mail3.rannagharplano.com. | 3600 | *(only after 2.6 gates pass)* |
| `@` | TXT | `v=spf1 ip4:104.237.138.198 ip4:172.104.58.45 ip4:47.190.50.190 -all` | 3600 |
| `mail1` / `mail2` / `mail3` | TXT | `v=spf1 a -all` | 3600 |
| `<sel>._domainkey` | TXT | from Stalwart | 3600 |
| `_dmarc` | TXT | `v=DMARC1; p=none; rua=...` | 3600 |
| `mta-sts` | CNAME | mail2.rannagharplano.com. | 3600 |
| `_mta-sts` | TXT | `v=STSv1; id=...` | 3600 |
| `_smtp._tls` | TXT | `v=TLSRPTv1; rua=...` | 3600 |
| `@` | CAA | `0 issue "letsencrypt.org"` | 3600 |
| `autoconfig` / `autodiscover` | CNAME | mail.rannagharplano.com. | 3600 |
| SRV records | SRV | see 4.7 | 3600 |
| **PTR for the two Linodes** (set at Linode, not in your zone) | PTR | mail1 / mail2 hostnames | — |
| **PTR for 47.190.50.190** (set by Frontier, or delegated to you) | PTR | mail3.rannagharplano.com. | — |

**Propagation:** create the A records **first**, wait until `dig +short mail2.rannagharplano.com @8.8.8.8` returns the right answer everywhere, *then* set PTR at Linode (it validates forward DNS), *then* run the deployment. ACME will fail against DNS that hasn't propagated.

---

# PART 5 — Firewall ports (you configure these; I don't touch them)

Nothing in `deploy.sh` installs or configures `ufw`, `firewalld`, `iptables` or `nftables`. Garage and Stalwart bind their own sockets and that is all.

**These nodes are not on a shared private network.** Every "cluster" row below is public-internet traffic between three specific IPs. Restrict each of those rules to the three source IPs — the internal ports must *never* be open to `0.0.0.0/0`.

`SG` = 172.104.58.45 · `US` = 104.237.138.198 · `OP` = 47.190.50.190

## 5.1 Public mail ports

| Port | Proto | Source | Destination | Purpose |
|---|---|---|---|---|
| 25 | TCP | `0.0.0.0/0` | **all three** | Inbound SMTP from the internet (MX 10/20/30). On mail3 this needs a router port-forward |
| 465 | TCP | `0.0.0.0/0` | mail2 | Submission over implicit TLS (SMTPS) — the modern client submission port |
| 587 | TCP | `0.0.0.0/0` | mail2 | Submission with STARTTLS. **Skip this** unless a client requires it |
| 993 | TCP | `0.0.0.0/0` | mail2 | IMAP over implicit TLS. On mail3, restrict to your LAN unless you want remote IMAP there |
| 443 | TCP | `0.0.0.0/0` | **all three** | HTTPS: JMAP, WebDAV, autoconfig, MTA-STS policy, OAuth |
| 80 | TCP | `0.0.0.0/0` | mail1, mail2 | HTTP→HTTPS redirect and HTTP-01 ACME fallback only |
| 25 | TCP | **all three** | `0.0.0.0/0` | **Outbound** delivery to the world. Requires the Linode block lifted, and Frontier not filtering |

> If `MAIL3_PUBLIC_MX=no`, drop mail3 from the 25 and 443 rows entirely and forward only 3901 and 7447 to it.

Deliberately **not** opened: 110/995 (POP3), 143 (plaintext IMAP), 4190 (ManageSieve). Stalwart's own hardening guidance says to disable ports 587, 143, 4190, 110/995 and 8080 if unused. PART 13 turns those listeners off inside the application too — closing the port and disabling the listener are different controls and you want both.

## 5.2 Cluster / internal ports

| Port | Proto | Source | Destination | Purpose |
|---|---|---|---|---|
| 7447 | TCP | SG, US, OP | SG, US, OP | **Stalwart Zenoh coordination.** Cache invalidation, IMAP IDLE fan-out, IP-ban propagation, ACME certificate distribution |
| 7446 | UDP | — | — | Zenoh multicast scouting. **Explicitly disabled** in our config; do not open it |

Full mesh: each node needs 7447 open *from* the other two. On the on-prem router this means a port-forward of TCP 7447 to the mail3 VM.

**On the on-prem router, the complete forward list is:** TCP 25, 443, 3901, 7447 → mail3's LAN address. (Drop 25 and 443 if `MAIL3_PUBLIC_MX=no`.) 3901 and 7447 are required either way — without them mail3 is not in the cluster at all.

## 5.3 Garage ports

| Port | Proto | Source | Destination | Purpose |
|---|---|---|---|---|
| 3901 | TCP | SG, US, OP | SG, US, OP | **Garage RPC.** Replication, layout sync, cluster gossip. The only Garage port that crosses the network |
| 3900 | TCP | 127.0.0.1 | localhost | S3 API. **Bound to loopback only** — each Stalwart node uses its own Garage |
| 3902 | TCP | 127.0.0.1 | localhost | S3 website endpoint. Loopback, unused |
| 3903 | TCP | 127.0.0.1 | localhost | Admin API + Prometheus metrics. Loopback only |

Full mesh on 3901; on-prem router needs a forward for it.

## 5.4 Database ports

| Port | Proto | Source | Destination | Purpose |
|---|---|---|---|---|
| 5432 | TCP | SG, US, OP | **US (mail2) only** | Stalwart → data store, and WAL streaming to the two standbys. TLS-only, scram-sha-256, `pg_hba` restricted to these three /32s |

If you later promote mail1, this rule moves to mail1.

## 5.5 Administration ports

| Port | Proto | Source | Destination | Purpose |
|---|---|---|---|---|
| 22 | TCP | **your admin IPs only** | all three | SSH. Key auth only |
| 8080 | TCP | **nothing** | mail2 | Stalwart bootstrap wizard. Reach it over an SSH local-forward, not by opening the port (PART 13.0) |
| 443 | TCP | `0.0.0.0/0` | mail2 | `/admin` WebUI rides on HTTPS. Restrict by source IP if you can; otherwise rely on 2FA + auto-ban |

## 5.6 Outbound from every node

| Port | Proto | Destination | Purpose |
|---|---|---|---|
| 53 | TCP+UDP | your resolvers | DNS. **TCP 53 matters** — DNSSEC and DKIM answers exceed 512 bytes |
| 80, 443 | TCP | `0.0.0.0/0` | ACME, package updates, DNSBL lookups, binary downloads |
| 123 | UDP | NTP pool | Time sync — see PART 6.3 |

---

# PART 6 — Node preparation

## 6.1 Installation method: native binaries, not Docker

| | Native + systemd | Docker Compose |
|---|---|---|
| Ports 25/465/993 | Direct bind, real client IPs | Needs `network_mode: host` or you lose source IPs — which breaks Stalwart's auto-ban and every IP-reputation check |
| Garage disk | Direct access to `/var/lib/garage` | Volume indirection; LMDB on an overlay fs is a documented corruption risk |
| Memory on a 2 GB node | ~100 MB Stalwart idle | Plus a daemon and per-container overhead you can't spare |
| Postgres | System packages, standard `pg_basebackup` | Another container to make stateful |
| Debugging | `journalctl -u stalwart` | Two log layers |
| Upstream support | Both projects ship first-class static binaries + systemd units and document them as the primary Linux path | Docker is documented as an option, not the recommendation |

Docker earns its keep when you're orchestrating many services or running Kubernetes. Here it adds a networking layer to three long-lived daemons on small VMs. **Native.**

## 6.2 Bootstrap — run on ALL THREE nodes

```bash
sudo install -d -m 0755 /opt/mailstack
# copy the mailstack bundle to /opt/mailstack (scp, git, or paste the files)
cd /opt/mailstack
sudo cp env.example .env
sudo chmod 600 .env
sudo chown root:root .env
sudo chmod +x deploy.sh bin/*.sh
```

### On mail2 ONLY — generate every secret at once

```bash
cd /opt/mailstack
sudo nano .env          # set NODE_NAME=mail2 and check the IPs/zones
sudo ./deploy.sh gen-secrets
```

`gen-secrets` fills every `CHANGE_ME` with `openssl rand` output **in place**, prints only the names of what it generated (never the values), and leaves the file at mode 600. Values you already set by hand are left alone.

### Copy the identical .env to the other two nodes

```bash
# from mail2
sudo scp /opt/mailstack/.env root@172.104.58.45:/opt/mailstack/.env
sudo scp /opt/mailstack/.env root@47.190.50.190:/opt/mailstack/.env
```

Then on **mail1**: `sudo chmod 600 /opt/mailstack/.env && sudo nano /opt/mailstack/.env` → change **only** `NODE_NAME=mail1`.
On **mail3**: same, `NODE_NAME=mail3`.

Every shared secret — the Garage RPC secret, the Postgres password, the cluster secret — must be byte-identical across the three nodes. Copying the file is how you guarantee that.

### Pre-flight, then prep — on ALL THREE nodes

```bash
sudo ./deploy.sh preflight     # read every WARN line
sudo ./deploy.sh prep
```

`prep` sets the static hostname, installs packages, enables time sync, applies sysctl and nofile limits, creates directories, and caps journald at 1 GB.

## 6.3 Time synchronisation — why it actually matters here

```bash
timedatectl status
timedatectl show-timesync --all | head -20
systemctl status systemd-timesyncd --no-pager
chronyc tracking 2>/dev/null || true    # only if you swap in chrony
```

Expected: `System clock synchronized: yes`, `NTP service: active`.

This is not box-ticking. In this specific stack, clock skew breaks things in ways that are hard to diagnose:

- **TLS certificate validation fails** if a node's clock is outside a certificate's validity window. A node 20 minutes fast will reject a freshly-issued Let's Encrypt certificate as not-yet-valid, and Postgres connections with `useTls: true` fail with a confusing error.
- **DKIM signatures carry a timestamp (`t=`) and optional expiry (`x=`).** A skewed signer produces signatures receivers treat as invalid — silently, from your point of view.
- **Garage stamps object versions with wall-clock time.** Garage resolves concurrent writes to the same key by timestamp. A node with a fast clock can make a stale write win over a newer one.
- **PostgreSQL replication lag becomes unreadable.** `now() - pg_last_xact_replay_timestamp()` compares the standby's clock against a timestamp from the primary. Skew shows up as negative or wildly inflated lag, so your monitoring lies to you.
- **Received: headers and message ordering** go wrong across nodes, and spam filters penalise messages whose dates are in the future.

If you want tighter control, install `chrony` instead — but `systemd-timesyncd` with the default NTP pool is fine at this scale.

---

# PART 7 — Garage installation

## 7.1 How Garage storage allocation *actually* works — read this before choosing numbers

This is the part of your plan that needed correcting, and the answer is not what most people expect.

**Garage's `capacity` is a per-node number, and with `replication_factor = 3` the cluster's usable capacity equals ONE node's capacity — not the sum.**

Straight from Garage's `layout show` output in the official docs, for three 1000 MB nodes in three zones:

```
Partitions are replicated 3 times on at least 3 distinct zones.
Usable capacity / total cluster capacity:   3.0 GB / 4.0 GB (75.0 %)
Effective capacity (replication factor 3):  1000.0 MB
```

Three nodes × 1000 MB = 3 GB of raw disk, and the **effective capacity is 1000 MB**. Every byte you PUT is written to all three nodes.

So the arithmetic is:

```
usable S3 space  ≈  per-node capacity          (replication_factor = 3, one zone per node)
raw disk needed  =  usable × 3                 (spread across the three nodes)
```

**There is no "30 GB total cluster quota" setting in Garage, because that is not how the layout algorithm thinks.** What you actually control:

1. **Per-node `capacity`** in the layout (`garage layout assign -c 25G`). This is the placement algorithm's input — it decides what share of the keyspace each node holds. It is a *declared weight*, and I could not find a statement in the docs that Garage hard-rejects writes when a node exceeds it, so **do not treat it as a disk guard**. Its job is to make the layout correct.
2. **A hard bucket quota** — `garage bucket set-quotas <bucket> --max-size 20GiB`. *This* is the real ceiling, enforced per bucket, and it is what actually stops a mail flood filling all three disks.
3. **Actual free disk**, which is the last line of defence and which you monitor (PART 18).

So your "≈30 GB for Garage" maps to this design:

- **Reserve 30 GB of disk on each node** for `/var/lib/garage` (data + metadata + snapshots).
- **Declare `capacity = 25G` per node** — 5 GB of headroom inside the reservation for LMDB metadata, auto-snapshots, and the temporary duplication that happens during a layout rebalance.
- **Set a hard bucket quota of 20 GiB** so Stalwart can never push the cluster to the edge.
- **Result: ~25 GB of usable, 3×-replicated S3 storage**, consuming ~90 GB of raw disk across the three nodes.

If you genuinely need 30 GB *usable*, you need 30 GB of Garage data on each node — 90 GB raw — and on a 50 GB disk that leaves too little for the OS, PostgreSQL and logs. Attach a Linode Block Storage volume to each Linode and mount it at `/var/lib/garage/data` first. Dropping to `replication_factor = 2` to buy space is **not** an option worth taking: with RF 2 and `consistency_mode = "consistent"` the write quorum is 2 of 2, so losing *any* node stops writes for the partitions it owned. That destroys the fault tolerance you're building this for.

## 7.2 Storage layout table — all three nodes

Per node, 50 GB disk:

| Path / purpose | Size | Notes |
|---|---|---|
| OS + packages (`/`, `/usr`, `/opt`) | 8 GB | Ubuntu 24.04 minimal ≈ 4 GB; leave room for upgrades |
| swap | 2 GB | small; `vm.swappiness=10` |
| `/var/lib/garage/data` | **24 GB** | The blob payload. Declared capacity 25G sits just above this so the layout is honest about the disk |
| `/var/lib/garage/meta` | **4 GB** | LMDB metadata. No published data:metadata ratio exists in Garage's docs — 4 GB is generous for ≤25 GB of 1 MB blocks; monitor it |
| `/var/lib/garage/snapshots` | **2 GB** | 6-hourly metadata auto-snapshots |
| `/var/lib/postgresql` | 6 GB | Primary on mail2, standbys on mail1/mail3 — same footprint either way. Mailbox *metadata* only; bodies are in Garage |
| `/var/lib/stalwart` | 1 GB | Local caches and ACME working state |
| `/var/log` + journal | 2 GB | journald capped at 1 GB by `prep` |
| `/var/backups/mailstack` | 2 GB | Encrypted bundles staged before shipping off-box |
| **Free headroom** | **~1 GB** | |
| **Total** | **~51 GB** | Tight. If you can add a block-storage volume, put `/var/lib/garage` on it |

> Note the shape of this: the mail *bodies* are the big thing, and they live in Garage, replicated three ways. PostgreSQL holds only metadata, which is why 6 GB is plenty.

## 7.3 Install Garage — run on ALL THREE nodes

```bash
cd /opt/mailstack
sudo ./deploy.sh garage
```

That command:
1. Downloads the static musl binary for **v2.4.0** to `/usr/local/bin/garage`.
2. Generates `/etc/garage.toml` from `.env` (mode 0640, `root:garage`) — symlinked to `/opt/garage/garage.toml`.
3. Creates a `garage` system user and a hardened systemd unit.
4. Starts the service and prints this node's ID.

**Verify the download URL if it fails.** The pattern is `https://garagehq.deuxfleurs.fr/_releases/v2.4.0/<arch>/garage`; the exact architecture string is listed on <https://garagehq.deuxfleurs.fr/download/>. Garage publishes no checksums or signatures on that page, so the HTTPS fetch is the integrity guarantee.

### The generated config, annotated

```toml
replication_factor = 3            # 3 copies, one per zone. NOT negotiable for HA.
consistency_mode   = "consistent" # read-after-write guaranteed. See below.

metadata_dir = "/var/lib/garage/meta"
data_dir     = "/var/lib/garage/data"
metadata_snapshots_dir = "/var/lib/garage/snapshots"

db_engine = "lmdb"                # default and recommended for RF >= 2
metadata_fsync = true             # LMDB corruption on power loss is a KNOWN issue
data_fsync     = false            # blocks are content-addressed; re-fetchable
metadata_auto_snapshot_interval = "6h"

rpc_secret      = "…"             # identical on all three nodes
rpc_bind_addr   = "[::]:3901"
rpc_public_addr = "<this node's public IP>:3901"
bootstrap_peers = []              # we connect explicitly instead

[s3_api]
api_bind_addr = "127.0.0.1:3900"  # LOOPBACK ONLY
s3_region     = "garage"

[admin]
api_bind_addr = "127.0.0.1:3903"  # LOOPBACK ONLY
metrics_require_token = true
```

**Two deliberate choices worth understanding:**

- `consistency_mode = "consistent"` keeps the read quorum at 2, guaranteeing read-after-write. Garage also offers `"degraded"` (read quorum 1) which would make reads local and therefore fast from Singapore. **Don't.** Stalwart writes a message body and may immediately read it back (`verifyAfterWrite` does a HEAD after every PUT), and a degraded read can miss a just-written object. Correctness beats latency for mail.
- `metadata_fsync = true`. Garage's own known-issues page states: *"Many users have reported situations where the LMDB metadata db becomes corrupted, sometimes after a forced shutdown of Garage or in case of power loss."* Your on-prem node is on residential power. This costs a little write throughput and buys you not rebuilding a node's metadata after a blackout.

### Read this node's identity

```bash
sudo garage -c /etc/garage.toml node id
```

Output looks like `563e1ac825ee…f1e6@104.237.138.198:3901`. Collect these from **mail1 and mail3**; you'll paste them on mail2 in the next step.

---

# PART 8 — Database installation

Order matters: **mail2 first**, then mail1, then mail3.

## NODE 2 — mail2.rannagharplano.com (the primary)

```bash
cd /opt/mailstack
sudo ./deploy.sh postgres
```

This installs PostgreSQL 16, generates a private CA and a server certificate for `db.rannagharplano.com`, writes a hardened `postgresql.conf` fragment and a `pg_hba.conf` that permits **only** the three node IPs over **TLS only** with **scram-sha-256**, creates the `stalwart` role and database and the `replicator` role, and creates the two replication slots.

Passwords are never passed on a command line — the role creation runs from a mode-600 temp SQL file, so nothing shows up in `ps`.

### Copy the CA to the other two nodes

The script prints this; here it is again:

```bash
sudo scp /opt/mailstack/pki/ca.crt root@172.104.58.45:/usr/local/share/ca-certificates/mailstack-ca.crt
sudo scp /opt/mailstack/pki/ca.crt root@47.190.50.190:/usr/local/share/ca-certificates/mailstack-ca.crt
# then on mail1 and mail3:
sudo update-ca-certificates
```

**Why a private CA and not Let's Encrypt?** Stalwart's PostgreSQL data-store object exposes `useTls` and `allowInvalidCerts` but no per-connection CA path, so the trust anchor has to be in the system store. A private CA you control, installed system-wide, gets you `useTls: true` **and** `allowInvalidCerts: false` — real authentication of the database server, not just encryption. Since your firewall already restricts 5432 to three /32s, this is defence in depth on a link that does cross the public internet.

> **Verify this works.** After PART 9, if Stalwart logs a TLS error connecting to Postgres, its client may not read the system trust store. Test it independently first: `psql "host=db.rannagharplano.com dbname=stalwart user=stalwart sslmode=verify-full"` from mail1. If that succeeds and Stalwart still fails, set `"allowInvalidCerts": true` in `/etc/stalwart/config.json` — you keep encryption and fall back to the IP allowlist for authentication — and tell me so I can chase the exact behaviour.

### Verify the primary

```bash
sudo -u postgres psql -c "SELECT version();"
sudo -u postgres psql -c "SELECT slot_name, active FROM pg_replication_slots;"
sudo -u postgres psql -c "SHOW ssl;"
sudo ss -tlnp | grep 5432
```

Expect two inactive slots (`mail1_slot`, `mail3_slot`) and `ssl = on`.

## NODE 1 — mail1.rannagharplano.com (standby)

```bash
sudo update-ca-certificates          # after copying the CA
cd /opt/mailstack
sudo ./deploy.sh postgres
```

Takes a `pg_basebackup` from `db.rannagharplano.com` over TLS with `sslmode=verify-full`, using the `mail1_slot` replication slot, and starts as a hot standby.

## NODE 3 — mail3.rannagharplano.com (standby)

```bash
sudo update-ca-certificates
cd /opt/mailstack
sudo ./deploy.sh postgres
```

Same, using `mail3_slot`.

## Verify replication (from mail2)

```bash
sudo -u postgres psql -x -c "
SELECT application_name, client_addr, state, sync_state, write_lag, replay_lag
  FROM pg_stat_replication;"
```

You want two rows, `state = streaming`, `sync_state = async`, and lag in the tens of milliseconds domestically / a couple of hundred to Singapore.

**Replication is asynchronous on purpose.** `synchronous_standby_names` is empty. Making Singapore a synchronous standby would put a full 200 ms Pacific round trip on every commit — every delivered message, every read flag. The cost of async is that a primary loss can drop the last few hundred milliseconds of WAL. For mail that means a message that was accepted but not yet replicated; the sending server will retry it, because it never got a final `250 OK`… which is exactly why we do **not** enable `synchronous_commit = off`. Keep `synchronous_commit = on` (durable to the primary's local disk) with async replicas — that is the correct setting and it is what the generated config uses.

---

# PART 9 — Stalwart installation

Order matters: **mail2 first** (it runs the setup wizard that provisions the shared database), then mail1 and mail3 (they just join).

## NODE 2 — mail2 (first, runs the wizard)

```bash
cd /opt/mailstack
sudo ./deploy.sh stalwart
```

Because there is no `/etc/stalwart/config.json` yet, Stalwart starts in **bootstrap mode** — mail services stay inactive and only the setup WebUI is served, on port 8080. The script pins the bootstrap credentials via `STALWART_RECOVERY_ADMIN` so you don't have to fish the one-time password out of the journal.

If you'd rather read it from the log anyway (the documented way):

```bash
sudo journalctl -u stalwart -n 200 | grep -A8 'bootstrap mode'
```

**Now go to PART 13 and complete the wizard.** Then come back here.

### After the wizard, re-run on mail2

```bash
sudo ./deploy.sh stalwart
```

The wizard writes a `config.json` with the database password inline. Re-running rewrites it so the password is referenced from the environment file instead:

```json
{
  "@type": "PostgreSql",
  "host": "db.rannagharplano.com",
  "port": 5432,
  "database": "stalwart",
  "authUsername": "stalwart",
  "authSecret": { "@type": "EnvironmentVariable", "variableName": "MAILSTACK_DB_PASSWORD" },
  "useTls": true,
  "allowInvalidCerts": false,
  "timeout": 15000,
  "poolMaxConnections": 10
}
```

`MAILSTACK_DB_PASSWORD` lives in `/etc/stalwart/stalwart.env` (mode 0600), loaded by a systemd drop-in. **No password is stored in `config.json`.** This is a documented Stalwart feature — secret-typed fields accept `{"@type":"EnvironmentVariable","variableName":"…"}` or `{"@type":"File","filePath":"…"}` as alternatives to an inline value.

## NODE 1 — mail1

```bash
cd /opt/mailstack
sudo ./deploy.sh stalwart
```

No wizard. `config.json` is written from `.env` pointing at the same PostgreSQL database, so this node inherits every setting, domain, account and DKIM key the wizard created. `STALWART_HOSTNAME=mail1.rannagharplano.com` in the env file gives it a unique node identity — Stalwart derives node IDs from the hostname and the docs warn that *"if two nodes share the same hostname they will compete for the same lease, which causes coordination conflicts and data inconsistencies."*

## NODE 3 — mail3

```bash
cd /opt/mailstack
sudo ./deploy.sh stalwart
```

Identical, `STALWART_HOSTNAME=mail3.rannagharplano.com`.

## Verify all three joined

```bash
sudo journalctl -u stalwart -n 50 --no-pager | grep -i -E 'cluster|node|coordinat'
sudo ss -tlnp | grep -E ':(25|443|465|993)\b'
```

Cluster membership is visible in the WebUI: **`https://mail.rannagharplano.com/admin` → Settings → Cluster**. You should see three nodes with their hostnames.

---

# PART 10 — .env files

**One file per node, identical except `NODE_NAME`.** The complete template is `env.example` in the bundle. Key points:

- `chmod 600` and `root:root` are **enforced** — `deploy.sh` refuses to run otherwise.
- Every deployment command reads from it; nothing is typed twice.
- `./deploy.sh gen-secrets` fills every `CHANGE_ME` with `openssl rand` output and prints only the *names* of what it set.
- Only two values are filled in later, by you: `S3_ACCESS_KEY` and `S3_SECRET_KEY`, which Garage generates in PART 12.

Where each secret ends up:

| `.env` variable | Consumed by | Written to | Mode |
|---|---|---|---|
| `GARAGE_RPC_SECRET` | Garage | `/etc/garage.toml` | 0640 `root:garage` |
| `GARAGE_ADMIN_TOKEN`, `GARAGE_METRICS_TOKEN` | Garage admin API | `/etc/garage.toml` | 0640 |
| `PG_APP_PASSWORD` | Postgres role + Stalwart | Postgres catalog; `/etc/stalwart/stalwart.env` | 0600 |
| `PG_REPL_PASSWORD` | replication | Postgres catalog; `postgresql.auto.conf` on standbys | 0600 |
| `S3_ACCESS_KEY` / `S3_SECRET_KEY` | Stalwart blob store | `/etc/stalwart/stalwart.env` | 0600 |
| `STALWART_BOOTSTRAP_ADMIN_PASSWORD` | bootstrap wizard | `/etc/stalwart/stalwart.env` (remove after setup) | 0600 |
| `STALWART_CLUSTER_SECRET` | Zenoh coordinator | settings DB (see PART 12.3 caveat) | — |
| `BACKUP_PASSPHRASE` | `bin/backup.sh` | nowhere — used in-memory | — |

Garage checks secret-file permissions itself and refuses to start on a world-readable secret unless `allow_world_readable_secrets = true` — which we leave at `false`.

---

# PART 11 — Configuration generation

Everything is generated from `.env`; you never hand-edit a generated file.

```
/opt/mailstack/
├── .env                      ← the ONE file you edit (0600)
├── env.example
├── deploy.sh                 ← the ONE command you run
├── lib/common.sh             ← env loading, permission enforcement, helpers
├── bin/verify.sh             ← read-only health check
├── bin/backup.sh             ← encrypted backup bundle
└── pki/                      ← private CA for Postgres TLS (mail2, 0700)

generated →
/etc/garage.toml              (0640 root:garage)  ← symlinked from /opt/garage/garage.toml
/etc/stalwart/config.json     (0640 root:stalwart) ← symlinked from /opt/stalwart/config.json
/etc/stalwart/stalwart.env    (0600 root:root)     ← symlinked from /opt/stalwart/stalwart.env
/etc/systemd/system/garage.service
/etc/systemd/system/stalwart.service.d/60-mailstack.conf
/etc/postgresql/16/main/conf.d/60-mailstack.conf
/etc/postgresql/16/main/pg_hba.conf
```

`/opt/garage/` and `/opt/stalwart/` exist as you asked, holding symlinks to the real files so you can find everything in one place without moving config off the paths the packages expect.

**Safety properties built into the generator:**
- Any existing file is copied to `<file>.mailstack.orig` before the first overwrite.
- Files are written atomically (`mktemp` + `chmod` + `mv`), so a crash mid-write can't leave a half-written config.
- `require_set` aborts with a clear message if a needed value is still `CHANGE_ME`, before anything is touched.
- `umask 077` is set at the top of every script.
- No secret is ever echoed. The only exception is the Garage S3 key pair, which `garage-cluster` must show you once so you can put it in `.env`.

To change a password later: edit `.env`, re-run the relevant phase (`./deploy.sh garage` or `./deploy.sh stalwart`), restart. For the Postgres password you must also `ALTER ROLE stalwart PASSWORD …` on the primary.

---

# PART 12 — Cluster formation

## 12.1 Garage cluster

### Step 1 — collect node IDs

**On NODE 1 (mail1):**
```bash
sudo garage -c /etc/garage.toml node id
```
**On NODE 3 (mail3):**
```bash
sudo garage -c /etc/garage.toml node id
```

Each prints `<64-hex-chars>@<public-ip>:3901`. Copy both in full.

### Step 2 — form the cluster, from NODE 2 (mail2) only

```bash
cd /opt/mailstack
sudo ./deploy.sh garage-cluster
```

It prompts for the two node IDs and then runs, in order:

```bash
garage node connect <mail1-id>@172.104.58.45:3901
garage node connect <mail3-id>@47.190.50.190:3901
garage status

garage layout assign <mail2-id-prefix> -z us-dallas    -c 25G -t mail2
garage layout assign <mail1-id-prefix> -z sg-singapore -c 25G -t mail1
garage layout assign <mail3-id-prefix> -z onprem-tx    -c 25G -t mail3
garage layout show
garage layout apply --version 1

garage bucket create stalwart-blobs
garage key create stalwart-app-key
garage bucket allow --read --write stalwart-blobs --key stalwart-app-key
garage bucket set-quotas stalwart-blobs --max-size 20GiB --max-objects none
garage admin-token create --expires-in 365d --scope GetClusterHealth,GetClusterStatus,GetClusterStatistics mailstack-monitor
garage key info stalwart-app-key --show-secret
```

**Notes on these commands, current as of v2.4.0:**
- `-c/--capacity` takes a `bytesize` value: suffixes `B, KB, MB, GB, TB, PB`, so `25G` is valid.
- **`--replace` on `layout assign` is long-form only** — there is no `-r` short flag for it. The `-r` short flag belongs to `garage layout config --redundancy`. Getting this wrong is an easy mistake to make from older tutorials.
- `garage layout apply` requires `--version N`, which `layout show` prints. This is a safety interlock: it makes you look at the staged layout before committing it.
- `garage key info` requires `--show-secret` to print the secret key.
- `bucket allow` grants `--read --write` but deliberately **not** `--owner`. The Stalwart key can put and get objects; it cannot delete the bucket, change permissions, or make it public.
- **The static `admin_token` is deprecated in favour of scoped tokens.** Garage's docs since v2.0: *"With the introduction of multiple user-defined admin tokens, the use of master API tokens is now discouraged."* We create a read-only scoped token for monitoring and leave the master token unused.

### Step 3 — put the S3 keys in .env, on all three nodes

`garage-cluster` prints the access key and secret key. Put them into `/opt/mailstack/.env` on **all three** nodes:

```
S3_ACCESS_KEY=GK…
S3_SECRET_KEY=…
```

Then run `sudo ./deploy.sh stalwart` on each node.

### Step 4 — verify the layout maths

```bash
sudo garage -c /etc/garage.toml layout show
```

You are looking for:

```
Zone redundancy: maximum
Partitions are replicated 3 times on at least 3 distinct zones.
Effective capacity (replication factor 3):  25.0 GB
```

If "Effective capacity" says ~75 GB, your replication factor didn't take and you have **no redundancy** — stop and fix `/etc/garage.toml` on every node.

## 12.2 Point Stalwart at Garage (blob store)

In the WebUI on mail2: **Settings → Storage → Blob Store**, or via `stalwart-cli`. The object is `BlobStore` with the `S3` variant and a **Custom** region, because Garage is not AWS:

```json
{
  "@type": "S3",
  "region": {
    "@type": "Custom",
    "customEndpoint": "http://127.0.0.1:3900",
    "customRegion": "garage"
  },
  "bucket": "stalwart-blobs",
  "accessKey": { "@type": "EnvironmentVariable", "variableName": "MAILSTACK_S3_ACCESS_KEY" },
  "secretKey": { "@type": "EnvironmentVariable", "variableName": "MAILSTACK_S3_SECRET_KEY" },
  "timeout": 30000,
  "maxRetries": 3,
  "verifyAfterWrite": true,
  "keyPrefix": "stalwart/"
}
```

**Every node uses `127.0.0.1:3900`** — its own local Garage. Garage does the WAN replication. Plain HTTP is correct here because the connection never leaves the loopback interface.

`verifyAfterWrite: true` (the default) issues a HEAD after each PUT. Garage's durability is good, but Stalwart's docs are blunt that *"Some backends silently lose data; verification defends against this"*, and for mail bodies you want that check. Keep it on.

> **Confirm the exact encoding on your build before applying.** The `@type` names for these wrapper values are schema-driven. Run this and compare against the JSON above:
> ```bash
> stalwart-cli --url https://mail.rannagharplano.com --user admin describe BlobStore
> ```
> If it reports a different variant name for the value wrapper (e.g. `Value` rather than `Text`/`EnvironmentVariable`), use what `describe` says — it is generated from the running server's own schema and is authoritative for your version.

## 12.3 Stalwart cluster coordination (Zenoh)

The `Coordinator` singleton is **cluster-wide** — you set it once, on any node, and all nodes read the same value from the shared database.

WebUI: **Settings → Cluster → Coordinator** → variant **Zenoh**. The object is:

```json
{
  "@type": "Zenoh",
  "config": "{ mode: \"peer\", listen: { endpoints: [\"tcp/0.0.0.0:7447\"] }, connect: { endpoints: [\"tcp/104.237.138.198:7447\", \"tcp/172.104.58.45:7447\", \"tcp/47.190.50.190:7447\"] }, scouting: { multicast: { enabled: false } } }"
}
```

The `config` field is a **JSON5 string** passed through to Eclipse Zenoh. What each piece does and why:

- `mode: "peer"` — full mesh, no central router. Matches the docs' "no central coordinator or dedicated server."
- `listen.endpoints: ["tcp/0.0.0.0:7447"]` — Zenoh's *default* peer listen endpoint is `tcp/[::]:0`, a **random** port. That is useless when you're writing firewall rules, so we pin 7447.
- `connect.endpoints` — all three node addresses, explicitly. Each node will try to connect to itself and harmlessly ignore that; listing all three means one config works on every node.
- `scouting.multicast.enabled: false` — multicast discovery (UDP `224.0.0.224:7446`) cannot work across the public internet. Turning it off avoids pointless traffic and keeps UDP 7446 closed.

**Security note, stated honestly:** TCP 7447 carries cluster control traffic across the public internet. Your **primary** control is the firewall — allow 7447 only from the other two node IPs, never from `0.0.0.0/0`. Zenoh additionally supports username/password transport auth and TLS links, which would look like this appended inside the same JSON5 object:

```
transport: { auth: { usrpwd: { user: "stalwart", password: "<STALWART_CLUSTER_SECRET>", dictionary_file: "/etc/stalwart/zenoh_users.txt" } } }
```

I have **not** been able to confirm from Stalwart's documentation that it passes the full `transport` section through to Zenoh — the docs say to *"refer to the Zenoh documentation for the full set of scouting, multicast, and connection options"*, which implies passthrough but does not promise it. Try it, then check `journalctl -u stalwart` for a config parse error. **If it doesn't take, do not deploy without the IP allowlist** — that firewall rule is not optional.

## 12.4 Cluster roles (optional but recommended)

Some Stalwart background tasks must run on exactly one node. The docs single out `spamClassifierTraining` as "single-node execution recommended", and `taskScheduler` owns ACME renewal and calendar alerts. Roles are defined as `ClusterRole` objects and assigned per node with the `STALWART_ROLE` environment variable.

Suggested split — create these under **Settings → Cluster → Roles**:

```toml
[[cluster.role]]
name = "primary"
description = "mail2: all listeners plus every singleton background task"
tasks = { type = "EnableAll" }
listeners = { type = "EnableAll" }

[[cluster.role]]
name = "edge"
description = "mail1: serves traffic, runs outbound MTA, no singleton tasks"
tasks = { type = "EnableSome", taskTypes = ["outboundMta", "taskQueueProcessing"] }
listeners = { type = "EnableAll" }

[[cluster.role]]
name = "internal"
description = "mail3: internal listeners only, no background tasks"
tasks = { type = "DisableAll" }
listeners = { type = "EnableAll" }
```

Then in `/etc/stalwart/stalwart.env` on each node add `STALWART_ROLE=primary` / `edge` / `internal` and restart. Available task types are `storeMaintenance`, `accountMaintenance`, `metricsCalculate`, `metricsPush`, `pushNotifications`, `searchIndexing`, `spamClassifierTraining`, `outboundMta`, `taskQueueProcessing`, `taskScheduler`.

**Leave roles unset if you want to keep it simple** — all nodes then run everything, which works for three nodes but means three nodes independently trying to train the spam classifier.

---

# PART 13 — Stalwart Web Administration GUI, click by click

## 13.0 First: reach the wizard safely

The bootstrap wizard listens on plain **HTTP port 8080**. You are about to type an admin password into it. **Do not open 8080 to the internet.** Tunnel it over SSH from your workstation:

```bash
ssh -N -L 8080:127.0.0.1:8080 root@104.237.138.198
```

Then browse to **`http://127.0.0.1:8080/admin`**.

| Field | Value |
|---|---|
| Username | `setupadmin` |
| Password | the value of `STALWART_BOOTSTRAP_ADMIN_PASSWORD` in `.env` |

Read the password without echoing the whole file:

```bash
sudo grep '^STALWART_BOOTSTRAP_ADMIN_PASSWORD=' /opt/mailstack/.env | cut -d= -f2-
```

> **A note on this section.** Field *labels* in the WebUI are rendered from the schema, so what you see reads like the schema field names quoted below (e.g. `defaultHostname`, `authSecret`). If a label reads slightly differently in your build, use the **global search box at the top** — it locates settings by name and is the fastest way to land on the right page. Anything I could not confirm from the docs is marked.

---

## 13.1 The setup wizard (mail2 only, once)

The wizard collects: server hostname, default domain, storage backends, directory authentication method, and the permanent administrator.

### Step 1 — Server identity

| Field | Enter | Why |
|---|---|---|
| Hostname | `mail.rannagharplano.com` | This becomes `defaultHostname` in SystemSettings. It is **cluster-wide, not per-node**. The docs are explicit: *"all backend nodes should use a consistent hostname that matches the public-facing identity of the service"*, and warn that failing to align it *"leads to inconsistent SMTP banners, TLS certificates, and protocol-level responses."* **Do not enter `mail2.rannagharplano.com` here.** |
| Default domain | `rannagharplano.com` | The organisational domain |

Click **Next**.

### Step 2 — Storage backend

| Field | Enter |
|---|---|
| Data store type | **PostgreSQL** |
| Host | `db.rannagharplano.com` |
| Port | `5432` |
| Database | `stalwart` |
| Username | `stalwart` |
| Password | the `PG_APP_PASSWORD` from `.env` |
| Use TLS | **✅ enabled** |
| Allow invalid certificates | ❌ **leave off** |
| Connection timeout | Leave at default (`15000` ms) |
| Pool max connections | Leave at default (`10`) |

> You are typing the password once, here. `./deploy.sh stalwart` re-run afterwards replaces it with an `EnvironmentVariable` reference so it does not persist in `config.json`.

**Blob store:** if the wizard offers it, choose **S3-compatible** and use the values from PART 12.2. If it does not, leave it at the default (blobs in the data store) and change it immediately after the wizard — instructions in 13.3. Do not leave blobs in PostgreSQL long-term: mail bodies in a single-primary SQL database is exactly the bottleneck this architecture exists to avoid.

**Search store / In-memory store:** **Leave both at default.** Elasticsearch or Meilisearch would be a fourth distributed system on 2 GB nodes. Redis for the in-memory store is worth revisiting only if you later see rate-limit state diverging between nodes.

### Step 3 — Directory / authentication

| Field | Enter |
|---|---|
| Directory type | **Internal** |
| Everything else | Leave at default |

Internal means accounts live in the same PostgreSQL data store, so they are automatically shared by all three nodes. Choose SQL or LDAP only if you already run an external identity source.

### Step 4 — Administrator account

| Field | Enter |
|---|---|
| Username | `admin` (your `STALWART_ADMIN_USER`) |
| Password | your `STALWART_ADMIN_PASSWORD` — 28 random characters from `gen-secrets` |
| Email / contact | `postmaster@rannagharplano.com` |

Click **Finish**. Stalwart writes `config.json`, creates the permanent admin, provisions the rest of the configuration, and restarts into normal operation. The WebUI moves to **`https://mail.rannagharplano.com/admin`** and `setupadmin` stops working.

### Step 5 — Immediately after

```bash
# on mail2: drop the pinned bootstrap credential and rewrite config.json
sudo sed -i '/^STALWART_RECOVERY_ADMIN=/d' /etc/stalwart/stalwart.env
cd /opt/mailstack && sudo ./deploy.sh stalwart
```

Leaving `STALWART_RECOVERY_ADMIN` in place leaves a second admin credential alive. The docs call recovery mode *"for emergencies only"* and say it *"should be removed after resolving the incident."*

---

## 13.2 Domains and DKIM

**Directory → Domains → `rannagharplano.com`** (or **+ Add domain** if it isn't there)

| Field | Value |
|---|---|
| Domain name | `rannagharplano.com` |
| Description | `Primary mail domain` |
| Certificate management | **Automatic** → ACME provider = the one you create in 13.4 |
| Subject alternative names | See 13.4 |

**DKIM keys.** On the domain page there is a DKIM section. Click **Generate keys** and create **both**:

| Field | Value |
|---|---|
| Algorithm 1 | **Ed25519**, selector `202609e` |
| Algorithm 2 | **RSA-2048**, selector `202609r` |
| Canonicalisation | Leave at default (`relaxed/relaxed`) |
| Header algorithm | `sha256` |

Two keys because Ed25519 signatures are smaller and stronger but some receivers still only validate RSA; publishing both means every receiver gets a signature it can check. Date-based selectors make rotation obvious a year from now.

After generating, the page shows the **DNS records to publish**. Copy them verbatim into your zone (PART 14). Then use the domain page's **DNS check** / **verify** action — Stalwart resolves your published records and tells you what is missing.

**Set `p=` correctly:** do not shorten, re-wrap, or re-base64 the key material. Copy it exactly.

---

## 13.3 Storage

**Settings → Storage → Blob Store**

| Field | Value |
|---|---|
| Type | **S3** |
| Region | **Custom** |
| Custom endpoint | `http://127.0.0.1:3900` |
| Custom region | `garage` |
| Bucket | `stalwart-blobs` |
| Access key | env reference `MAILSTACK_S3_ACCESS_KEY` (or paste the value) |
| Secret key | env reference `MAILSTACK_S3_SECRET_KEY` |
| Timeout | Leave at default (`30000`) |
| Max retries | Leave at default (`3`) |
| Verify after write | **✅ leave enabled** |
| Key prefix | `stalwart/` |
| Allow invalid certs | ❌ off |

**Settings → Storage → Data Store** — **Leave everything at default.** This mirrors `config.json` and changing it here without changing `config.json` will break startup.

**Settings → Storage → Search Store** and **In-Memory Store** — **Leave at default.**

---

## 13.4 TLS and ACME

**Settings → TLS → ACME Providers → + Add**

| Field | Value | Why |
|---|---|---|
| Name | `letsencrypt` | |
| Directory URL | `https://acme-v02.api.letsencrypt.org/directory` | The default; Let's Encrypt production |
| Contact | `postmaster@rannagharplano.com` | Expiry warnings |
| Challenge type | **`Dns01`** | **This is the important one — see below** |
| DNS server | the `DnsServer` object you create next | |
| Renew before | Leave at default (`R23`) | |
| Max retries | Leave at default (`10`) | |
| EAB key ID / HMAC | Leave empty | Only needed for ZeroSSL-style CAs |

### Why DNS-01 and not the default TLS-ALPN-01

This is the single most common way a Stalwart cluster's TLS setup fails, and it is worth understanding rather than just copying.

- **TLS-ALPN-01** requires the CA to connect to **port 443 of the IP the hostname resolves to**, and get an ACME-specific certificate back.
- **HTTP-01** requires the CA to fetch a token from **port 80 of the IP the hostname resolves to**.

Both are fine for one server with one name. Your cluster has three hostnames resolving to three different IPs, one shared certificate, and — per the roles documentation — ACME renewal running as a `taskScheduler` task on **one** node. When mail2 tries to validate `mail1.rannagharplano.com` by TLS-ALPN-01, Let's Encrypt connects to *mail1's* IP, mail1 has no idea a challenge is in flight, and validation fails.

**DNS-01 has no such coupling.** The validating node publishes a TXT record at `_acme-challenge.<name>` via your DNS provider's API; the CA reads DNS. Any node can validate any name. It also enables wildcards.

**Settings → DNS → DNS Servers → + Add**

Stalwart v0.16 supports Cloudflare, AWS Route 53, Google Cloud DNS, OVH, deSEC, DigitalOcean, Bunny DNS, Porkbun, DNSimple, Spaceship, and self-hosted BIND over RFC 2136 with either a TSIG shared key or a SIG(0) key pair.

Cloudflare example:

| Field | Value |
|---|---|
| Provider | `Cloudflare` |
| API token | your scoped token (`ACME_DNS_API_TOKEN`) |
| TTL / polling / propagation | Leave at defaults |

Scope the token to **Zone → DNS → Edit** on `rannagharplano.com` **only**. A global API key here is a domain-takeover credential sitting on a mail server.

### The certificate: one SAN certificate, not per-node, not wildcard

**Directory → Domains → `rannagharplano.com` → Certificate management: Automatic**, and set **Subject alternative names** to:

```
mail.rannagharplano.com
mail1.rannagharplano.com
mail2.rannagharplano.com
mail3.rannagharplano.com
autoconfig.rannagharplano.com
autodiscover.rannagharplano.com
mta-sts.rannagharplano.com
rannagharplano.com
```

Why a **SAN certificate** rather than the alternatives:

- **Per-node certificates** would mean three certificates, three renewal paths, and three chances for one to silently expire — and they fight the architecture, because the docs say ACME state lives in the shared data store and newly issued certificates are automatically distributed to all nodes. Certificates here are a *cluster* resource.
- **A wildcard** (`*.rannagharplano.com`) works technically (DNS-01 supports it) but a wildcard key on a mail server is a key that can impersonate *every* host in your domain, including future ones. If that box is compromised, the blast radius is the whole domain. A SAN certificate lists exactly the eight names that exist.

**Settings → General → SystemSettings**

| Field | Value |
|---|---|
| `defaultCertificateId` | the certificate above | Served to clients that don't send SNI |
| `defaultHostname` | `mail.rannagharplano.com` | |

### Renewal

Automatic. `renewBefore` defaults to `R23` (renew at ~23 remaining periods of validity — i.e. well before expiry) and the `taskScheduler` cluster task drives it. New certificates are pushed to every node over the Zenoh bus.

**Verify renewal works before you rely on it:**

```bash
# 30 days after issuance, confirm notAfter has moved forward:
echo | openssl s_client -connect mail.rannagharplano.com:993 \
      -servername mail.rannagharplano.com 2>/dev/null \
  | openssl x509 -noout -dates
```
Put a calendar reminder at day 30. An unnoticed renewal failure becomes an outage at day 90.

---

## 13.5 Listeners — turn off what you don't use

**Settings → Server → Listeners**

| Listener | Port | Setting | Action |
|---|---|---|---|
| SMTP | 25 | `useTls` on, `tlsImplicit` **off** (STARTTLS) | **Enabled on all three** once mail3's 2.6 gates pass. Disable on mail3 if `MAIL3_PUBLIC_MX=no` |
| Submissions | 465 | `useTls` on, `tlsImplicit` **on** | **Enabled on mail2.** Disable on mail1/mail3 |
| Submission | 587 | STARTTLS | **Disable** unless a client demands it |
| IMAPS | 993 | `useTls` on, `tlsImplicit` **on** | **Enabled on mail2** (and mail3 for LAN) |
| IMAP | 143 | plaintext | **Disable** |
| POP3 / POP3S | 110 / 995 | | **Disable both.** You have IMAP and JMAP; POP3 is one more attack surface for no gain |
| ManageSieve | 4190 | | **Disable** unless you hand users Sieve scripts |
| HTTP | 443 | `useTls` on, `tlsImplicit` on | **Enabled** — JMAP, WebDAV, `/admin`, autoconfig, MTA-STS |
| HTTP | 8080 | plaintext | **Disable after setup** |

For each listener you keep:

| Field | Value |
|---|---|
| `tlsDisableProtocols` | disable TLS 1.0 and TLS 1.1 |
| `tlsDisableCipherSuites` | Leave at default — Stalwart's defaults are modern; hand-picking cipher suites usually makes things worse |
| `tlsIgnoreClientOrder` | Leave at default |
| `tlsTimeout` | Leave at default |

This matches the docs' own hardening list: keep 25, 465, 993, 443; disable 587, 143, 4190, 110/995, 8080 if unused.

---

## 13.6 Authentication and administrators

**Directory → Accounts → `admin`**

| Field | Value |
|---|---|
| Password | your 28-character generated password |
| Two-factor authentication | **✅ Enable TOTP.** Do this now, not later |
| Email access (IMAP/JMAP/WebDAV) | **Disabled** — the docs say administrator accounts should *"never"* be used for mail access and *"these services should be isolated from administrative functions"* |

**Directory → Accounts → + Add** — create a **second, separate** administrator with its own password and TOTP, for account recovery when the first is locked out.

**Directory → Roles** — the docs recommend *"multiple administrator accounts with specific, limited permissions"* rather than one shared superadmin. At minimum split:

| Role | Permissions |
|---|---|
| `user-admin` | Create/modify accounts and groups. No server settings |
| `queue-admin` | View and manage the mail queue and reports. No account access |
| `superadmin` | Everything. Used rarely, TOTP mandatory |

**Directory → Authentication**

| Field | Value |
|---|---|
| Password hashing | Leave at default (Argon2id) |
| App passwords | **Enable** — so mail clients that can't do TOTP use a scoped credential instead of the real password |
| API keys | Enable only if you script against the API |

**Real user accounts:** **Directory → Accounts → + Add**

| Field | Value |
|---|---|
| Name | e.g. `rana` |
| Email | `rana@rannagharplano.com` |
| Type | Individual |
| Quota | Set one. **Do not leave unlimited** — with a 20 GiB bucket quota, one runaway mailbox can exhaust the cluster. 2 GB per user is a sane start |
| Roles | `user` |

Also create `postmaster@`, `abuse@`, `dmarc-reports@`, `tls-reports@` — RFC 2142 requires the first two and the reports go nowhere without the others.

---

## 13.7 SMTP — inbound

**Settings → MTA → Inbound**

| Stage | Field | Value |
|---|---|---|
| Connect | Max concurrent connections | Leave at default |
| EHLO | Require valid EHLO | **Enable** — rejects the least sophisticated spam sources |
| EHLO | Reject EHLO that doesn't resolve | **Enable** |
| MAIL FROM | SPF verification | **Enable**, strict |
| MAIL FROM | Reject on SPF hard fail | **Enable** |
| RCPT TO | Max recipients per message | `100` |
| RCPT TO | Reject unknown recipients | **Enable.** Critical: accepting mail for non-existent users and bouncing later makes you a backscatter source and gets you blocklisted |
| RCPT TO | Rate limit | see 13.10 |
| DATA | Max message size | `50 MB` (bodies go to Garage, but a 25 GB bucket and 50 MB messages still means capacity planning) |
| DATA | DKIM / DMARC / ARC verification | **Enable all** |
| DATA | Spam filter | **Enable** |

### Relay restrictions — the one that must not be wrong

**Settings → MTA → Inbound → RCPT stage → relay policy**

| Setting | Value |
|---|---|
| Allow relay for **authenticated** sessions | ✅ **Yes** |
| Allow relay for **unauthenticated** sessions | ❌ **NO** |
| Allow relay from any IP range | ❌ **NO** — do not add a "trusted network" range |

An open relay is discovered by scanners within hours and gets your IPs on the Spamhaus PBL/XBL permanently. **Verify it explicitly after deployment — PART 15.6 has the exact test.**

## 13.8 SMTP — outbound

**Settings → MTA → Outbound**

| Field | Value | Why |
|---|---|---|
| Outbound IP / source address | mail2 → `104.237.138.198`; mail1 → `172.104.58.45`; mail3 → `47.190.50.190` (or your dedicated outbound IP) | Must match SPF and PTR exactly, or your own SPF fails you |
| EHLO hostname | the node's own FQDN (`mail2.rannagharplano.com`) | Must match forward and reverse DNS |
| Require TLS | **Opportunistic** (default) | `Required` breaks delivery to the many small servers with no TLS |
| DANE | **Enable (opportunistic)** | Uses TLSA when the recipient publishes it |
| MTA-STS | **Enable** | Honour recipients' published policies |
| Retry schedule | Leave at default | Stalwart's defaults follow standard backoff |
| Queue expiry | `5 days` (default) | The RFC-recommended give-up point |
| Max concurrent outbound | `10` per destination | Slow down; new IPs that blast get throttled |

**mail3 outbound — two phases:**

| Phase | Setting |
|---|---|
| **Until PTR + port 25 verified, and for the first ~2 weeks after** | Outbound strategy = **relay through mail2** (`mail2.rannagharplano.com:465`, authenticated). mail3 handles inbound only while its IP has no sending history |
| **After warm-up** | Outbound strategy = **direct**, source IP `47.190.50.190` (or your dedicated outbound IP), EHLO `mail3.rannagharplano.com` |

Do not skip the relay phase. A cold IP that starts delivering at volume gets throttled by Gmail and Microsoft, and that throttling is applied to *your domain* as much as to the IP.

**Queue settings:** **Settings → MTA → Outbound → Queues** — leave the default queue at defaults. Consider a separate lower-concurrency queue for bulk/notification mail later.

## 13.9 IMAP, JMAP, POP3

**Settings → Email → IMAP**

| Field | Value |
|---|---|
| Max concurrent connections per user | `10` |
| IDLE timeout | Leave at default |
| Max authentication failures | `3` (feeds auto-ban) |

**Settings → HTTP → JMAP** — **Leave at defaults.** JMAP is the modern protocol and Stalwart's defaults are sensible.

**POP3** — disabled at the listener (13.5). Nothing else to configure.

**Settings → Email → Maintenance** — leave at defaults; this drives the `accountMaintenance` cluster task.

## 13.10 Rate limits and brute-force protection

**Settings → Server → Auto-Ban**

| Field | Value | Why |
|---|---|---|
| Enable auto-ban | ✅ | The docs describe it as automatically blocking IPs that *"attempt brute-force password attacks, guess account names, scan for vulnerabilities, or launch SYN flood attacks"* |
| Authentication failure threshold | `5` per IP | |
| Ban duration | `1 hour`, escalating | |
| Scanner/probe detection | ✅ Enable | |
| Allowlist | **your own admin IPs** | So you can't lock yourself out |

Bans propagate to all three nodes over the Zenoh bus — an attacker banned at mail2 is banned at mail1 too. That is one of the concrete reasons the cluster coordination exists.

**Settings → Email → Rate Limiting** and **Settings → HTTP → Rate Limiting**

| Limit | Value |
|---|---|
| Messages per authenticated user per hour | `200` |
| Recipients per user per hour | `500` |
| Failed auth attempts per IP per minute | `5` |
| JMAP/HTTP requests per IP per minute | Leave at default |

The outbound rate limit is not about abuse from strangers — it is the blast radius when one of *your* users' credentials is phished. Without it, a compromised account sends 50,000 messages overnight and your IPs are blocklisted by morning.

## 13.11 Spam controls

**Settings → Spam Filter**

| Field | Value |
|---|---|
| Enable spam filter | ✅ |
| Linear classifier | ✅ Enable |
| Autolearning | ✅ Enable |
| DNS blocklists | ✅ Enable defaults (Spamhaus ZEN, etc.) |
| Greylisting | **Enable**, ~5 minutes. Very effective; costs first-time senders a short delay |
| Spam threshold / scores | **Leave at defaults** until you have weeks of real traffic. Tuning scores blind causes false positives |
| LLM classifier | **Leave disabled** — it needs an AI model backend and is Enterprise |
| Phishing protection | ✅ Enable |
| Trusted senders | Add your own domains |
| Spamtrap | Leave at default |

**Important with cluster roles:** `spamClassifierTraining` should run on **one node only** (mail2). Three nodes independently training against the same store is wasted work and can produce inconsistent models.

## 13.12 DNS settings

**Settings → DNS → Resolver**

| Field | Value |
|---|---|
| Resolver | System default, or `1.1.1.1` / `9.9.9.9` explicitly |
| DNSSEC validation | **Enable** |
| Cache TTL | Leave at default |

Mail servers are extremely DNS-heavy (SPF, DKIM, DMARC, MX, DNSBL, MTA-STS). A slow or lossy resolver shows up as mysterious delivery delays. Make sure **TCP 53** is open outbound — DNSSEC and DKIM answers routinely exceed 512 bytes and fall back to TCP.

## 13.13 Cluster settings

**Settings → Cluster → Coordinator** — Zenoh, as in PART 12.3.
**Settings → Cluster → Roles** — as in PART 12.4.
**Settings → Cluster → Nodes** — read-only; confirm three nodes with distinct hostnames.

If you see fewer than three, or two entries with the same name, stop: a duplicate hostname means two nodes are fighting over the same node-ID lease, which the docs warn *"causes coordination conflicts and data inconsistencies."*

## 13.14 Settings to leave alone

Explicitly: **leave these at their defaults.**

- Search Store and In-Memory Store backends
- Sieve interpreter limits
- TLS cipher suites and curve preferences
- JMAP protocol limits and push settings
- WebDAV / CalDAV / CardDAV settings (unless you're using them)
- Spam scores and hyperparameters
- Outbound retry/backoff schedule
- ASN/GeoIP (needs a data source you don't have)
- AI models (Enterprise)
- Tenants (Enterprise, and you are single-tenant)
- Encryption (S/MIME, OpenPGP) — per-user features, not server policy
- Caching
- Branding

---

# PART 14 — DNS / DKIM / SPF / DMARC after installation

Records in PART 4 were publishable before installation. These come **out of** the running server.

## 14.1 Read the real DKIM records

**WebUI:** Directory → Domains → `rannagharplano.com` → DKIM → each key shows its DNS record.

**CLI:**
```bash
export STALWART_URL=https://mail.rannagharplano.com
export STALWART_USER=admin
# password prompted interactively — do not put it in the environment on a shared box
stalwart-cli query DkimSignature --json | jq .
```

Publish exactly what it gives you:

```
202609e._domainkey.rannagharplano.com. 3600 IN TXT "v=DKIM1; k=ed25519; h=sha256; p=<exact base64>"
202609r._domainkey.rannagharplano.com. 3600 IN TXT "v=DKIM1; k=rsa; h=sha256; p=<exact base64>"
```

## 14.2 Verify each record actually resolves

```bash
dig +short TXT 202609e._domainkey.rannagharplano.com
dig +short TXT 202609r._domainkey.rannagharplano.com
dig +short TXT rannagharplano.com   | grep spf1
dig +short TXT _dmarc.rannagharplano.com
dig +short MX  rannagharplano.com
dig +short -x  104.237.138.198
dig +short -x  172.104.58.45
dig +short TXT _mta-sts.rannagharplano.com
dig +short CAA rannagharplano.com
curl -s https://mta-sts.rannagharplano.com/.well-known/mta-sts.txt
```

The RSA `p=` value is long. If `dig` returns it split across multiple quoted strings, that is correct — DNS concatenates them.

## 14.3 End-to-end authentication test

The definitive test is to have a receiver tell you what it saw:

```bash
# 1. Send to the check-auth robot; it replies with a full report.
swaks --to check-auth@verifier.port25.com \
      --from rana@rannagharplano.com \
      --server mail2.rannagharplano.com --port 465 --tlsc \
      --auth LOGIN --auth-user rana@rannagharplano.com

# 2. Or use mail-tester.com: get an address from the site, send to it,
#    then load the results page.
```

You want **SPF: pass**, **DKIM: pass** (both signatures), **DMARC: pass**, and a Spamassassin score ≥ 8/10.

Send a message to a Gmail address you own, then **Show original**: `SPF: PASS`, `DKIM: PASS`, `DMARC: PASS`.

## 14.4 The DMARC ramp

Do not skip this.

| Week | Record | What you're doing |
|---|---|---|
| 1–2 | `p=none; rua=...` | Collecting reports. Read them in WebUI → Reports → DMARC |
| 3 | `p=quarantine; pct=25` | Quarantining a quarter of failures. Watch for complaints |
| 4 | `p=quarantine; pct=100` | |
| 5+ | `p=reject` | Only once reports show 100% of legitimate mail passing |

Publishing `p=reject` on day one is the single most common way to make your own mail disappear.

---

# PART 15 — Verification

Run `sudo /opt/mailstack/bin/verify.sh` on each node for the automated sweep. Below are the individual checks and what "good" looks like.

## 15.1 Services

```bash
systemctl status garage --no-pager
systemctl status postgresql --no-pager
systemctl status stalwart --no-pager
sudo ss -tlnp | grep -E ':(25|443|465|993|3900|3901|3903|5432|7447)\b'
```

## 15.2 Garage cluster — all three nodes see the same cluster

Run **on each node** and compare:

```bash
sudo garage -c /etc/garage.toml status
```

Expected: the same three node IDs, the same tags (`mail1`/`mail2`/`mail3`), the same zones, and the **same layout version** on all three. If node A shows layout version 1 and node B shows 2, they have not converged — check RPC connectivity on 3901.

```bash
sudo garage -c /etc/garage.toml layout show
sudo garage -c /etc/garage.toml stats
curl -s -H "Authorization: Bearer $GARAGE_ADMIN_TOKEN" http://127.0.0.1:3903/health
```

`/health` returns **200 OK** when quorum is achieved and **503** when it is not.

## 15.3 An object written through one node is readable from another

This is your Test 12 / Test 6, and it is the real proof the Garage cluster works.

**On mail1 (Singapore):**
```bash
export AWS_ACCESS_KEY_ID=<S3_ACCESS_KEY>
export AWS_SECRET_ACCESS_KEY=<S3_SECRET_KEY>
echo "written on mail1 at $(date -u --iso-8601=seconds)" > /tmp/xnode.txt
s3cmd --host=127.0.0.1:3900 --host-bucket= --no-ssl \
      put /tmp/xnode.txt s3://stalwart-blobs/tests/xnode.txt
```

**On mail3 (on-prem), immediately:**
```bash
export AWS_ACCESS_KEY_ID=<S3_ACCESS_KEY>
export AWS_SECRET_ACCESS_KEY=<S3_SECRET_KEY>
s3cmd --host=127.0.0.1:3900 --host-bucket= --no-ssl \
      get s3://stalwart-blobs/tests/xnode.txt - 
```

The mail1 text must come back. It travelled Singapore → (replication) → Texas without either node talking to the other's S3 API — each spoke only to its own loopback.

**On mail2, confirm three replicas exist:**
```bash
sudo garage -c /etc/garage.toml bucket info stalwart-blobs
sudo garage -c /etc/garage.toml stats | grep -i -E 'block|resync'
```

Clean up: `s3cmd --host=127.0.0.1:3900 --host-bucket= --no-ssl del s3://stalwart-blobs/tests/xnode.txt`

## 15.4 Database

```bash
# on any node — can it reach the primary over TLS with full verification?
psql "host=db.rannagharplano.com port=5432 dbname=stalwart user=stalwart sslmode=verify-full" -c "SELECT now();"

# on mail2
sudo -u postgres psql -x -c "SELECT * FROM pg_stat_replication;"
sudo -u postgres psql -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';"

# on mail1/mail3
sudo -u postgres psql -c "SELECT pg_is_in_recovery(), now()-pg_last_xact_replay_timestamp() AS lag;"
```

## 15.5 Stalwart cluster

```bash
sudo journalctl -u stalwart --since "10 min ago" | grep -i -E 'cluster|zenoh|coordinat|peer'
```
WebUI → Settings → Cluster → Nodes: **three** nodes, distinct hostnames.

Live proof the coordination bus works: open an IMAP client against mail2, and deliver a message via mail1 (`swaks --server mail1...`). The client should be notified within a second or two without polling. That notification travelled over Zenoh.

## 15.6 SMTP

```bash
# TLS and banner
openssl s_client -starttls smtp -connect mail2.rannagharplano.com:25 -crlf
openssl s_client -connect mail2.rannagharplano.com:465 -crlf

# inbound acceptance for a real user
swaks --to rana@rannagharplano.com --from test@example.com \
      --server mail2.rannagharplano.com --port 25

# unknown recipient MUST be rejected at RCPT, not accepted and bounced
swaks --to nosuchuser@rannagharplano.com --from test@example.com \
      --server mail2.rannagharplano.com --port 25
#   expect: 550 5.1.1

# *** OPEN RELAY TEST — this MUST fail ***
swaks --to someone@gmail.com --from attacker@evil.example \
      --server mail2.rannagharplano.com --port 25
#   expect: 550 relay not permitted   (a 250 here is an emergency)

# authenticated submission MUST succeed
swaks --to someone@gmail.com --from rana@rannagharplano.com \
      --server mail2.rannagharplano.com --port 465 --tlsc \
      --auth LOGIN --auth-user rana@rannagharplano.com
```

Repeat the open-relay test against **mail1** as well.

## 15.7 IMAP / JMAP

```bash
openssl s_client -connect mail2.rannagharplano.com:993 -crlf
#   a1 LOGIN rana@rannagharplano.com <password>
#   a2 LIST "" "*"
#   a3 SELECT INBOX
#   a4 LOGOUT

curl -s -u rana@rannagharplano.com https://mail.rannagharplano.com/.well-known/jmap | jq .
```

## 15.8 TLS

```bash
echo | openssl s_client -connect mail.rannagharplano.com:993 \
        -servername mail.rannagharplano.com 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

Check: issuer is Let's Encrypt, `notAfter` ~90 days out, and the SAN list contains all eight names from 13.4. Do the same on port 465 and 443, and against `mail1.rannagharplano.com` — the *same* certificate should be served, proving cluster distribution worked.

## 15.9 Autoconfiguration

```bash
curl -s "https://autoconfig.rannagharplano.com/mail/config-v1.1.xml?emailaddress=rana@rannagharplano.com" | head -40
curl -s "https://autodiscover.rannagharplano.com/autodiscover/autodiscover.xml" -X POST -d '<Autodiscover/>' | head -20
curl -s https://mta-sts.rannagharplano.com/.well-known/mta-sts.txt
```

---

# PART 16 — Failure testing

Do these **before** you put real mail on the system, in this order. Restore between tests.

## TEST 1 — Stop Stalwart on node 1. Can I still access mail?

```bash
# on mail1
sudo systemctl stop stalwart
```
**Expected:**
- ✅ IMAP/JMAP on `mail.rannagharplano.com` (mail2) unaffected — users notice nothing.
- ✅ Inbound mail: senders get a connection refusal on MX 20 and immediately try MX 10 (mail2) or MX 30 (mail3). **This is real failover, not round-robin.**
- ✅ `swaks --server mail2... ` still delivers.
- ⚠️ mail1's outbound queue is frozen until it returns; queued messages resume on restart, they are not lost (the queue is in the shared database).

Verify: `swaks --to rana@rannagharplano.com --from test@example.com --server rannagharplano.com` — MX-based delivery still works.

Restore: `sudo systemctl start stalwart`

## TEST 1b — Stop the whole of node 3 (the on-prem box)

This is the one that will actually happen — office power, a router reboot, an ISP blip.

```bash
# on mail3
sudo shutdown -h now
```
**Expected: nothing user-visible.**
- ✅ Inbound mail: senders skip MX 30, use MX 10 or MX 20.
- ✅ IMAP/JMAP on mail2 unaffected.
- ✅ Garage: 2 of 3 zones, quorum holds, reads and writes both fine.
- ✅ Postgres primary unaffected; `mail3_slot` goes inactive.
- ⚠️ **Watch retained WAL** on the primary if it stays down for days (see TEST 3).

Verify from mail2:
```bash
sudo garage -c /etc/garage.toml status                      # mail3 shown as failed
curl -s -H "Authorization: Bearer $GARAGE_ADMIN_TOKEN" http://127.0.0.1:3903/health   # still 200
swaks --to rana@rannagharplano.com --from test@example.com --server rannagharplano.com
```

## TEST 1c — Stop node 2 (the answer to "what if the important one dies")

```bash
# on mail2
sudo systemctl stop stalwart postgresql
```
**Expected — and this is the honest one:**
- ✅ Garage keeps working from mail1 + mail3.
- ✅ Inbound SMTP connections to mail1 and mail3 are *accepted*, then return a `4xx` temporary failure because the data store is gone. **Sending servers queue and retry. No mail is lost.**
- ❌ IMAP/JMAP is down everywhere. Users see "cannot connect".
- ❌ Outbound is queued.

**This is expected behaviour, not a bug** — see 2.7. Recovery is TEST 8. Restore with `sudo systemctl start postgresql stalwart` and confirm the other nodes reconnect within a few seconds:
```bash
# on mail1
sudo journalctl -u stalwart -n 30 | grep -i -E 'data store|postgres|reconnect'
```

## TEST 2 — Stop Garage on node 1. Does S3 still work?

```bash
# on mail1
sudo systemctl stop garage
```
**Expected:**
- ✅ From **mail2** and **mail3**: reads and writes both succeed. `replication_factor = 3` with `consistency_mode = "consistent"` gives a quorum of 2, and 2 of 3 zones are alive.
- ❌ From **mail1 itself**: its local S3 endpoint on `127.0.0.1:3900` is gone, so Stalwart on mail1 cannot fetch message bodies. Mail1 can still accept SMTP into the queue, but IMAP body fetches from mail1 will fail.
- On mail2: `garage status` shows mail1 as failed/unavailable.

```bash
# on mail2 — writes still work with one zone down:
s3cmd --host=127.0.0.1:3900 --host-bucket= --no-ssl put /tmp/t.txt s3://stalwart-blobs/tests/t.txt
curl -s -H "Authorization: Bearer $GARAGE_ADMIN_TOKEN" http://127.0.0.1:3903/health
```
`/health` should still be 200 — quorum holds.

Restore: `sudo systemctl start garage`, then watch resync: `sudo garage -c /etc/garage.toml stats | grep -i resync`

## TEST 3 — Disconnect node 1 from the network entirely

Use the Linode console (not SSH — you'll cut yourself off) to detach the interface, or from the Linode LISH console:
```bash
sudo ip link set eth0 down; sleep 300; sudo ip link set eth0 up
```
**Expected:**
- ✅ mail2 and mail3 continue serving. Garage marks mail1 down; quorum of 2 holds.
- ✅ Postgres primary on mail2 keeps accepting writes. `mail1_slot` becomes inactive and WAL accumulates.
- ⚠️ **Watch `pg_wal` growth.** An inactive replication slot makes the primary retain WAL indefinitely — that is how a primary fills its disk during a long outage. `wal_keep_size = 512MB` bounds the *keep* setting but a slot overrides it. If mail1 will be down for days, drop the slot:
  ```bash
  sudo -u postgres psql -c "SELECT pg_drop_replication_slot('mail1_slot');"
  ```
  and recreate it plus re-basebackup when it returns.
- ✅ No split-brain is possible. mail1 is isolated from the only writable database, so it cannot diverge.

## TEST 4 — Create a mailbox on node 1, verify from node 2

```bash
# on mail1
export STALWART_URL=https://mail1.rannagharplano.com
stalwart-cli --user admin create Account \
  '{"name":"testuser","email":"testuser@rannagharplano.com","quota":1073741824}'

# on mail2 — immediately
export STALWART_URL=https://mail2.rannagharplano.com
stalwart-cli --user admin query Account --json | jq '.[] | select(.name=="testuser")'
```
**Expected:** appears instantly on mail2. There is one database; there is no replication delay to wait for. Also visible on mail3.

Clean up: `stalwart-cli --user admin delete Account testuser`

## TEST 5 — Send mail through node 1, read it via node 2/3

```bash
swaks --to testuser@rannagharplano.com --from external@example.com \
      --server mail1.rannagharplano.com --port 25 \
      --header "Subject: cross-node test $(date -u +%s)"
```
Then, on **mail2**:
```bash
openssl s_client -connect mail2.rannagharplano.com:993 -crlf
#   a1 LOGIN testuser@rannagharplano.com <password>
#   a2 SELECT INBOX
#   a3 FETCH 1 (BODY[])
```
**Expected:** the message is there with full body. Two things just happened: the metadata came from PostgreSQL in Dallas, and the body came from mail2's *local* Garage — which had received the replica from mail1's Garage in Singapore. Both halves of the architecture proved out in one test.

## TEST 6 — Upload an S3 object through node 1, retrieve through node 2

Covered in PART 15.3. Run it now if you skipped it.

## TEST 7 — Reboot node 1, confirm it rejoins

```bash
sudo reboot
```
**Expected on return, without any manual step:**
```bash
systemctl is-enabled garage postgresql stalwart   # all 'enabled'
sudo garage -c /etc/garage.toml status            # 3 nodes, same layout version
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"   # 't'
sudo -u postgres psql -c "SELECT now()-pg_last_xact_replay_timestamp();"  # lag shrinking to ~0
sudo journalctl -u stalwart -b | grep -i cluster
```
Garage resyncs any blocks it missed automatically. Check `garage stats | grep -i resync` until the queue is empty.

**If Postgres does not reconnect:** the slot may have been dropped or WAL recycled. Recover with a fresh base backup — `sudo ./deploy.sh postgres` on mail1 handles it (it detects the existing `standby.signal`; delete `/var/lib/postgresql/16/main/standby.signal` first to force a full rebuild).

## TEST 8 — Database failure: exactly what happens, and the recovery

```bash
# on mail2
sudo systemctl stop postgresql
```

**What happens, precisely:**

| Component | Behaviour |
|---|---|
| Stalwart on **all three** nodes | Loses the data store. **All mail service stops** — no IMAP, no JMAP, no SMTP acceptance. Logs fill with connection errors |
| Inbound SMTP | Stalwart returns `4xx` temporary failures. Sending servers **queue and retry** — mail is delayed, not lost. This is the correct behaviour and why a DB outage is survivable |
| Garage | **Completely unaffected.** Blobs stay readable |
| Standbys on mail1/mail3 | Still up, read-only, holding the data as of the last replayed WAL |

**This is the single point of failure in the design, and here is the runbook for it.**

### Promote a standby

**First decide which one.** Per 2.9, promote the standby with the *lowest latency to the rest of the cluster*. If mail2 and mail3 are in the same metro, that is **mail3** (`47.190.50.190`). If mail3 is also down or is unreliable, use mail1 (`172.104.58.45`) and accept ~200 ms until mail2 is rebuilt.

The commands below use `<NEW_PRIMARY_IP>` — substitute the one you picked.

```bash
# 1. Confirm the old primary is really down. Never promote while it might return.
ssh root@104.237.138.198 'systemctl is-active postgresql' || echo "confirmed down"

# 2. On the chosen standby — check it is the more up-to-date of the two first:
sudo -u postgres psql -c "SELECT pg_last_wal_replay_lsn();"
#    (compare against the other standby; promote whichever is further ahead)

# 3. Promote.
sudo -u postgres pg_ctl promote -D /var/lib/postgresql/16/main
# or:  sudo -u postgres psql -c "SELECT pg_promote();"
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"     # must return 'f'

# 4. Make it accept application + replication connections.
#    Edit /opt/mailstack/.env on that node:  PG_ROLE=db-primary
#    then re-run the primary configuration:
cd /opt/mailstack && sudo ./deploy.sh postgres

# 5. Repoint DNS — this is the whole switchover.
#    db.rannagharplano.com   A -> <NEW_PRIMARY_IP>    (TTL 60)
#    mail.rannagharplano.com A -> <NEW_PRIMARY_IP>    (TTL 60)

# 6. Restart Stalwart on the two surviving nodes so their pools reconnect.
sudo systemctl restart stalwart

# 7. Point the OTHER surviving standby at the new primary:
#    edit DB_HOSTNAME's target (DNS already did it) and re-basebackup:
sudo rm -f /var/lib/postgresql/16/main/standby.signal
cd /opt/mailstack && sudo ./deploy.sh postgres

# 8. Move the firewall rule for 5432 so inbound is allowed to the new primary.
```

> **If you promoted mail3**, also lower its MX preference or temporarily remove MX 30 — you do not want the node carrying the database to also be first in line for inbound SMTP floods on a consumer-grade uplink.

**Total time: about two minutes**, most of it DNS TTL. Queued inbound mail is retried by senders automatically.

### Rebuilding the old primary as a standby

**Do not just start the old mail2 back up.** Two primaries with the same identity is the one genuinely dangerous state here.

```bash
# on mail2, after the new primary is confirmed:
sudo systemctl stop postgresql
sudo rm -rf /var/lib/postgresql/16/main/*
# set PG_ROLE=db-standby in .env (DB_HOSTNAME already points at the new primary via DNS)
cd /opt/mailstack && sudo ./deploy.sh postgres
```

### Should you automate this?

See **2.9** for the full argument. Short version: start manual with good alerting; if your measured mail2 ↔ mail3 latency is under 40 ms, Patroni + etcd becomes a defensible addition later, because a Singapore partition then leaves etcd quorum intact between the two nearby nodes.

## TEST 9 — Kill a whole zone's disk (the one people skip)

```bash
# on mail3 — simulate metadata corruption
sudo systemctl stop garage
sudo mv /var/lib/garage/meta /var/lib/garage/meta.broken
sudo systemctl start garage    # will fail
```
**Expected:** mail3's Garage won't start; mail1+mail2 keep quorum and serve everything. Recovery is to restore the metadata snapshot, or to remove and re-add the node with `garage layout assign <new-id> --replace <old-id> -c 25G -z onprem-tx -t mail3`. Restore with `sudo mv /var/lib/garage/meta.broken /var/lib/garage/meta`.

---

# PART 17 — Backup

## 17.1 Replication is not a backup. Say it out loud.

You asked me not to claim otherwise, and I won't — but it's worth being precise about *why*, because "we have 3× replication" is the most common reason small deployments have no backups.

Replication is a **fidelity** mechanism. It copies whatever happens, including the things you didn't want to happen:

- `DROP TABLE` on the Postgres primary is on both standbys in milliseconds.
- Deleting an object in Garage propagates the delete to all three zones. There is no undelete.
- A bad Stalwart upgrade that mangles the settings objects mangles them once, in the one database everyone reads.
- A compromised admin account operates on the *live* cluster; every node obediently reflects it.
- Ransomware encrypting `/var/lib/garage/data` on one node just makes that node's blocks fail checksums — but ransomware that gets your S3 key deletes objects cluster-wide.

Replication protects against **hardware and site failure**. Backups protect against **you, your software, and your attackers**. You need both, and they are not substitutes.

## 17.2 What must be backed up

| # | Item | Where | Why it's on the list | Recreatable? |
|---|---|---|---|---|
| 1 | **DKIM private keys** | Stalwart settings DB | Lose these and every signature you ever made is unverifiable; you must regenerate keys and republish DNS, and mail in flight fails DMARC | ❌ **No** |
| 2 | **PostgreSQL database** | mail2 | Every mailbox, message metadata, account, folder, flag, setting, rule | ❌ No |
| 3 | **`.env`** | all nodes | Every secret. Without it you cannot rebuild the cluster | ❌ No |
| 4 | **Stalwart settings snapshot** | via `stalwart-cli snapshot` | Domains, accounts, roles, listeners, TLS, spam rules — as a replayable apply plan | ❌ No |
| 5 | **Garage metadata** | `/var/lib/garage/meta` per node | The map from S3 keys to blocks. Without it the data blocks are unreadable rubble | ⚠️ Partly — rebuildable from peers if ≥1 node survives |
| 6 | **Garage object data** | `/var/lib/garage/data` | The message bodies themselves | ⚠️ Only if a replica survives |
| 7 | **`/etc/garage.toml`, `/etc/stalwart/config.json`** | all nodes | Regenerable from `.env`, but keep them for forensics | ✅ Yes |
| 8 | **Postgres CA + server key** | `/opt/mailstack/pki` on mail2 | Regenerable, but regenerating means redistributing the CA to every node | ✅ Yes |
| 9 | **TLS certificates** | Stalwart settings DB | ACME will just reissue them | ✅ Yes |
| 10 | **Garage layout** | cluster state | Text output; keep a copy so you can rebuild identically | ✅ Yes |

## 17.3 The plan for a ~25 GB deployment

```bash
sudo /opt/mailstack/bin/backup.sh
```

Produces one AES-256 encrypted bundle per run in `/var/backups/mailstack/`, containing items 1–5, 7, 8 and 10 above, and prunes bundles older than `BACKUP_RETENTION_DAYS`.

**Schedule:**

| What | Frequency | Where it goes | Retention |
|---|---|---|---|
| `backup.sh` on **mail2** (includes the full `pg_dump`) | **Hourly** | local, then rsync off-box | 14 days local, 90 days off-box |
| `backup.sh` on mail1 + mail3 (config/secrets half) | Daily | local, then off-box | 14 / 90 days |
| **Garage blob sync to an off-site S3** | Daily | Backblaze B2 / Wasabi / another Garage | 30 days, versioning on |
| Full restore rehearsal | **Quarterly** | a throwaway VM | — |

Cron entries:

```bash
# mail2
sudo crontab -e
0 * * * *  /opt/mailstack/bin/backup.sh >> /var/log/mailstack-backup.log 2>&1
30 3 * * * rsync -az --delete /var/backups/mailstack/ backup-host:/srv/mailstack/mail2/

# mail1 and mail3
0 4 * * *  /opt/mailstack/bin/backup.sh >> /var/log/mailstack-backup.log 2>&1
30 4 * * * rsync -az --delete /var/backups/mailstack/ backup-host:/srv/mailstack/$(hostname -s)/
```

**The off-site blob copy** — this is the one that costs money and the one people skip:

```bash
# daily, from mail2
AWS_ACCESS_KEY_ID=$S3_ACCESS_KEY AWS_SECRET_ACCESS_KEY=$S3_SECRET_KEY \
  rclone sync :s3,endpoint=http://127.0.0.1:3900:stalwart-blobs \
               b2:rannagharplano-mail-backup \
               --transfers 4 --fast-list
```

25 GB at Backblaze B2 is a few dollars a month. It is the difference between "we lost a datacenter" and "we lost the mail".

## 17.4 The three-copy rule, applied here

- **Copy 1:** live, replicated across three sites (Garage + Postgres standbys). Protects against hardware/site failure.
- **Copy 2:** hourly encrypted bundles on a machine that is **not** part of the cluster. Protects against mistakes and bad upgrades.
- **Copy 3:** daily off-site blob + bundle copy at a different provider, with object versioning and **immutability/object-lock if available**. Protects against a compromised admin credential deleting copies 1 and 2.

Store `BACKUP_PASSPHRASE` in a password manager, **not** only in `.env` — `.env` is inside the backup it decrypts.

## 17.5 Restore procedures

**Restore Stalwart settings + accounts + DKIM (most common):**
```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:BACKUP_PASSPHRASE \
  -in mail2-2026….tar.gz.enc | tar -xzf - -C /tmp/restore
stalwart-cli apply --file /tmp/restore/stalwart-snapshot.ndjson --dry-run
stalwart-cli apply --file /tmp/restore/stalwart-snapshot.ndjson
```
The snapshot is an *apply plan* built from upsert operations, so it is idempotent and safe to re-run.

**Restore the database:**
```bash
sudo systemctl stop stalwart          # on all three nodes first
sudo -u postgres dropdb stalwart
sudo -u postgres createdb -O stalwart stalwart
sudo -u postgres pg_restore -d stalwart /tmp/restore/stalwart-db.dump
sudo systemctl start stalwart
```

**Restore a Garage node's metadata:**
```bash
sudo systemctl stop garage
sudo tar -xf /tmp/restore/garage-meta-snapshot.tar -C /var/lib/garage/
# point metadata_dir at the restored snapshot, or move it into place
sudo systemctl start garage
sudo garage -c /etc/garage.toml repair -a --yes tables
```

**Test the restore quarterly.** An untested backup is a rumour.

---

# PART 18 — Monitoring

## 18.1 The five commands to run when something feels wrong

```bash
sudo /opt/mailstack/bin/verify.sh            # everything, one page
sudo garage -c /etc/garage.toml status       # cluster membership
sudo -u postgres psql -c "SELECT * FROM pg_stat_replication;"   # on the primary
sudo journalctl -u stalwart -p err --since "1 hour ago" --no-pager
df -h /
```

## 18.2 Per-component

**Stalwart**
```bash
systemctl status stalwart --no-pager
journalctl -u stalwart -f
journalctl -u stalwart -p err --since today --no-pager
journalctl -u stalwart --since "10 min ago" | grep -iE 'cluster|zenoh|peer'
ss -tnp | grep stalwart | wc -l          # active connections
```
WebUI → Telemetry → Metrics / Live Telemetry / Event history. Stalwart exports OpenTelemetry and Prometheus.

**Mail queue and failed mail**
```bash
stalwart-cli query QueuedMessage --json | jq 'length'
stalwart-cli query QueuedMessage --json | jq '.[] | select(.status!="pending") | {rcpt,status,lastError}'
```
WebUI → Operational → Queued messages (retry, hold, delete individual messages), and → Reports → DMARC / TLS / ARF.

**A growing queue is your earliest warning** of a blocklisting or a DNS problem. Alert on depth > 50.

**Garage**
```bash
systemctl status garage --no-pager
journalctl -u garage -f
garage -c /etc/garage.toml status
garage -c /etc/garage.toml stats -a
garage -c /etc/garage.toml worker list
garage -c /etc/garage.toml block list-errors        # corrupted/missing blocks
garage -c /etc/garage.toml layout show
curl -s -H "Authorization: Bearer $GARAGE_ADMIN_TOKEN" http://127.0.0.1:3903/health
curl -s -H "Authorization: Bearer $GARAGE_METRICS_TOKEN" http://127.0.0.1:3903/metrics | head -40
```
`block list-errors` returning anything non-empty means blocks failed checksum or went missing — run `garage repair -a --yes blocks`.

**PostgreSQL**
```bash
systemctl status postgresql --no-pager
sudo -u postgres psql -c "SELECT count(*), state FROM pg_stat_activity GROUP BY state;"
sudo -u postgres psql -c "SELECT * FROM pg_stat_replication;"                  # primary
sudo -u postgres psql -c "SELECT now()-pg_last_xact_replay_timestamp() AS lag;" # standby
sudo -u postgres psql -c "SELECT slot_name, active,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
  FROM pg_replication_slots;"
sudo -u postgres psql -c "SELECT pg_size_pretty(pg_database_size('stalwart'));"
tail -f /var/lib/postgresql/16/main/log/postgresql-*.log
```
**Watch `retained` WAL.** An inactive slot growing past a gigabyte is a primary heading for a full disk.

**System**
```bash
df -h / /var/lib/garage /var/lib/postgresql
du -sh /var/lib/garage/data /var/lib/garage/meta
free -h
vmstat 1 5
top -b -n1 | head -20
ss -s
ss -tn state established | wc -l
uptime
```

**TLS expiry**
```bash
for h in mail.rannagharplano.com mail1.rannagharplano.com mail2.rannagharplano.com; do
  printf '%-32s ' "$h"
  echo | openssl s_client -connect "$h:443" -servername "$h" 2>/dev/null \
    | openssl x509 -noout -enddate
done
```

## 18.3 Alert on these, at these thresholds

| Metric | Warn | Critical | Why |
|---|---|---|---|
| Disk free on `/` | < 20% | **< 10%** | The #1 killer. Postgres refuses writes and LMDB corrupts when the disk fills |
| `garage_*` health / `/health` | — | **≠ 200** | Quorum lost |
| Garage nodes visible | < 3 | < 2 | Below 2 zones, `consistent` mode reads fail |
| Postgres replication lag | > 30 s | > 5 min | Failover would lose that much |
| Retained WAL on a slot | > 1 GB | > 4 GB | Dead standby about to fill the primary |
| Mail queue depth | > 50 | > 500 | Blocklisting or DNS failure |
| Failed auth attempts / min | > 20 | > 100 | Credential-stuffing in progress |
| TLS cert days remaining | < 21 | **< 7** | ACME renewal has failed |
| Stalwart cluster node count | < 3 | < 2 | Coordination broken |
| Time offset | > 1 s | > 5 s | See PART 6.3 |
| Memory available | < 300 MB | < 150 MB | OOM killer about to take Postgres |
| Your IPs on a DNSBL | any | Spamhaus | Deliverability emergency |

Scrape Garage at `127.0.0.1:3903/metrics` and Stalwart's Prometheus endpoint into whatever you already run (Prometheus + Alertmanager, Netdata, Zabbix, Uptime Kuma). If you run nothing today, start with **Uptime Kuma on a fourth cheap box** checking: TCP 25/465/993 on mail2, HTTPS on mail.rannagharplano.com, certificate expiry, and the Garage `/health` endpoint via SSH — that alone catches most of what will actually go wrong.

**Also monitor from outside the cluster:** an MXToolbox or Hetrix blacklist monitor on both sending IPs. Finding out you're on the CBL from a customer complaint is finding out too late.

---

# PART 19 — Troubleshooting

### Stalwart won't start after `deploy.sh stalwart`
```bash
sudo journalctl -u stalwart -n 100 --no-pager
sudo -u stalwart /usr/local/bin/stalwart --config /etc/stalwart/config.json --help
sudo cat /etc/stalwart/config.json | jq .            # is it valid JSON?
sudo ls -l /etc/stalwart/stalwart.env               # must be 0600
sudo systemctl show stalwart -p EnvironmentFiles
```
Most common causes: `MAILSTACK_DB_PASSWORD` not reaching the process (check the systemd drop-in loaded), or the data store unreachable.

### `could not connect to server` / TLS error to PostgreSQL
```bash
psql "host=db.rannagharplano.com port=5432 dbname=stalwart user=stalwart sslmode=verify-full" -c "SELECT 1;"
psql "host=db.rannagharplano.com port=5432 dbname=stalwart user=stalwart sslmode=require"     -c "SELECT 1;"
dig +short db.rannagharplano.com
sudo tail -50 /var/lib/postgresql/16/main/log/postgresql-*.log
```
- `verify-full` fails but `require` works → the CA isn't trusted. Re-copy `ca.crt` and `update-ca-certificates`.
- `no pg_hba.conf entry` → the source IP isn't in the allowlist, or you're connecting without TLS to a `hostssl` line.
- Both fail → firewall, or `listen_addresses`.
- If `psql` with `verify-full` works but **Stalwart** still fails TLS, set `"allowInvalidCerts": true` in `config.json` as a documented fallback and rely on the IP allowlist.

### Garage nodes won't connect
```bash
sudo garage -c /etc/garage.toml status
sudo journalctl -u garage -n 100 --no-pager | grep -i -E 'rpc|connect|secret'
timeout 5 bash -c 'exec 3<>/dev/tcp/104.237.138.198/3901' && echo reachable
sudo grep -c rpc_secret /etc/garage.toml
```
- **`Connection refused` / silent failure** → TCP 3901 not open, or the on-prem port-forward is missing.
- **Handshake failures** → `rpc_secret` differs between nodes. It must be byte-identical. Re-copy `.env` and re-run `./deploy.sh garage`.
- **Node connects then drops** → `rpc_public_addr` is wrong (a private/NAT address instead of the public one).

### Garage layout versions differ between nodes
```bash
sudo garage -c /etc/garage.toml layout history
sudo garage -c /etc/garage.toml layout show
```
Nodes converge automatically once connected. If one is stuck because another is permanently dead:
```bash
sudo garage -c /etc/garage.toml layout skip-dead-nodes --version <N>
```

### "Effective capacity" is 3× what I expected
`replication_factor` isn't 3 on every node. Check `/etc/garage.toml` on all three and restart. **Note the version trap:** the old key was `replication_mode`; Garage v2.0 split it into `replication_factor` + `consistency_mode`. A config copied from a pre-2.0 tutorial will not do what you think.

### Cluster nodes don't see each other (Stalwart)
```bash
sudo journalctl -u stalwart | grep -i zenoh
timeout 5 bash -c 'exec 3<>/dev/tcp/172.104.58.45/7447' && echo reachable
sudo ss -tlnp | grep 7447
hostnamectl --static                      # must be unique per node
sudo grep STALWART_HOSTNAME /etc/stalwart/stalwart.env
```
Two nodes with the same hostname compete for one node-ID lease — the docs warn this causes *"coordination conflicts and data inconsistencies."*

### ACME / certificate issuance fails
```bash
sudo journalctl -u stalwart | grep -i -E 'acme|challenge|certificate'
dig +short TXT _acme-challenge.mail.rannagharplano.com
dig +short CAA rannagharplano.com
```
- CAA record forbidding Let's Encrypt → fix the CAA record.
- Using TLS-ALPN-01 in a cluster → switch to DNS-01 (13.4).
- DNS provider token lacking write permission → re-scope it.
- Let's Encrypt rate limits: 5 failed validations/hour, 50 certs/domain/week. **Test against the staging directory first**: `https://acme-staging-v02.api.letsencrypt.org/directory`.

### Mail is being delivered to spam
```bash
dig +short TXT rannagharplano.com | grep spf1
dig +short -x 104.237.138.198
swaks --to check-auth@verifier.port25.com --from rana@rannagharplano.com --server mail2... --port 465 --tlsc --auth LOGIN
```
In order of likelihood: PTR missing or mismatched; SPF doesn't list the actual sending IP; DKIM selector not published or `p=` mangled; a brand-new IP with no sending history (warm up slowly — dozens of messages a day, not thousands); the IP is on a DNSBL (check <https://multirbl.valli.org/>).

### Outbound mail stuck in queue
```bash
stalwart-cli query QueuedMessage --json | jq '.[] | {rcpt, status, lastError, nextRetry}'
timeout 5 bash -c 'exec 3<>/dev/tcp/gmail-smtp-in.l.google.com/25' && echo "port 25 out OK"
dig +short MX gmail.com
```
`Connection timed out` to everything on 25 → your provider still blocks outbound 25. Open the Linode ticket.

### Disk full
```bash
df -h; du -sh /var/lib/* /var/log/* 2>/dev/null | sort -h | tail -20
sudo journalctl --vacuum-size=500M
sudo -u postgres psql -c "SELECT slot_name, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) FROM pg_replication_slots;"
sudo garage -c /etc/garage.toml stats
```
Order of suspects: retained WAL from an inactive replication slot; journald; Garage data exceeding its declared capacity; Postgres bloat (`VACUUM FULL` during a maintenance window).

### One node is slow (and it's mail1)
Expected, not a fault. mail1 is ~200 ms from the database. See PART 2.4. If Singapore users need fast IMAP, the answer is to move the Postgres primary to Singapore (accepting that US users then pay the latency), not to tune anything.

### Turning mail3 into a full mail node (the 2.6 gates)
In order, and do not skip ahead:
1. Frontier sets PTR for `47.190.50.190` → `mail3.rannagharplano.com` (or delegates `50.190.47.in-addr.arpa` to you). Verify: `dig +short -x 47.190.50.190` **and** `dig +short mail3.rannagharplano.com` must agree.
2. Verify outbound 25 from mail3, and **inbound 25 from outside your network**.
3. Set `MAIL3_PUBLIC_MX=yes` in `.env` on all three nodes.
4. Enable the SMTP:25 listener on mail3 (13.5). Router forwards TCP 25 and 443.
5. Add `ip4:47.190.50.190` to SPF. Wait for the TTL.
6. Add `rannagharplano.com. MX 30 mail3.rannagharplano.com.`
7. Leave outbound relaying through mail2 for ~2 weeks, then switch to direct (13.8).
8. Watch the DMARC reports and check both `47.190.50.190` and your Linode IPs on <https://multirbl.valli.org/> weekly for the first month.

### Frontier won't set reverse DNS
Then mail3 must not send mail. Set `MAIL3_PUBLIC_MX=no`, keep its outbound strategy as "relay through mail2", and do not publish MX 30 or add it to SPF. It remains a full Garage replica, a PostgreSQL standby and a LAN IMAP/JMAP endpoint — you lose a third MX, which is not much, and you keep your domain's reputation, which is a lot.

### Inbound 25 works from mail1/mail2 but not from the wider internet
Some ISPs filter inbound 25 at the edge even on business plans, and some CGNAT/router setups only forward correctly for certain source ranges. Test from a third-party host (a cheap VPS elsewhere, or an online SMTP tester). If it's genuinely filtered, treat it as "Frontier won't set reverse DNS" above.

---

# PART 20 — Final checklist

## Pre-deployment
- [ ] Linode ticket filed and **resolved** to unblock outbound TCP 25 on both Linodes
- [ ] PTR set for mail1 and mail2 in the Linode console, verified with `dig -x`
- [ ] **Frontier has set PTR for 47.190.50.190 → mail3.rannagharplano.com** (or delegated the /26 reverse zone), verified with `dig -x`
- [ ] **Inbound TCP 25 to 47.190.50.190 tested from outside your network**
- [ ] **Outbound TCP 25 from mail3 tested**
- [ ] `MAIL3_PUBLIC_MX` set to `yes` or `no` based on those three results
- [ ] Inter-node latency measured; DB failover target chosen (2.9)
- [ ] DNS provider API token created, scoped to this zone only
- [ ] On-prem router forwards TCP 25, 443, 3901 and 7447 to the mail3 VM
- [ ] All A records published and propagated

## Nodes
- [ ] **Node 1 (mail1, Singapore) healthy** — `deploy.sh status` clean, `verify.sh` exits 0
- [ ] **Node 2 (mail2, USA) healthy**
- [ ] **Node 3 (mail3, on-prem) healthy**
- [ ] Static hostname correct and unique on each node
- [ ] `timedatectl` shows synchronised on all three
- [ ] `.env` is mode 600, root-owned, on all three
- [ ] `.env` is byte-identical except `NODE_NAME`

## Garage
- [ ] **Garage cluster healthy** — `garage status` shows 3 nodes from every node
- [ ] Same layout version on all three nodes
- [ ] `layout show` reports `Zone redundancy: maximum` and 3 distinct zones
- [ ] **"Effective capacity (replication factor 3)" ≈ 25 GB** — not 75 GB
- [ ] Bucket `stalwart-blobs` exists with a 20 GiB quota
- [ ] Key `stalwart-app-key` has read+write, **not owner**
- [ ] Bucket website access denied; bucket is not public
- [ ] S3 API bound to 127.0.0.1 only on every node (`ss -tlnp | grep 3900`)
- [ ] Cross-node object test passed (write on mail1, read on mail3)

## Database
- [ ] **Database healthy** — primary on mail2 accepting TLS connections
- [ ] Both standbys `state = streaming` in `pg_stat_replication`
- [ ] `sslmode=verify-full` works from mail1 and mail3
- [ ] `pg_hba.conf` allows only the three node IPs, `hostssl`, scram-sha-256
- [ ] Replication slots exist and are **active**
- [ ] Promote procedure rehearsed at least once (TEST 8)

## Stalwart
- [ ] **Stalwart cluster healthy** — 3 nodes in Settings → Cluster → Nodes
- [ ] Coordinator set to Zenoh, multicast disabled, explicit endpoints
- [ ] `defaultHostname` = `mail.rannagharplano.com` on all nodes
- [ ] Blob store points at `http://127.0.0.1:3900`, bucket `stalwart-blobs`
- [ ] No password in `config.json` — all via `EnvironmentVariable`
- [ ] `STALWART_RECOVERY_ADMIN` removed from `stalwart.env` on mail2
- [ ] Bootstrap port 8080 listener disabled
- [ ] Unused listeners disabled: 110, 143, 587, 995, 4190

## DNS and email authentication
- [ ] **DNS correct** — A, MX (10 mail2 / 20 mail1 / 30 mail3), no MX pointing at a CNAME
- [ ] **PTR correct on all three sending IPs**, matching forward DNS — including `47.190.50.190` from Frontier
- [ ] **SPF correct** — lists exactly the sending IPs, ends `-all`
- [ ] **DKIM correct** — both Ed25519 and RSA published, `p=` values exact
- [ ] **DMARC correct** — published at `p=none`, `rua` mailbox exists and receives reports
- [ ] MTA-STS TXT + policy file served over HTTPS
- [ ] TLS-RPT and CAA published
- [ ] autoconfig / autodiscover / SRV records published
- [ ] No AAAA records unless IPv6 mail is fully working with PTR
- [ ] No TLSA records until DNSSEC is signed
- [ ] mail-tester.com / port25 verifier score ≥ 8/10, SPF+DKIM+DMARC all pass

## TLS
- [ ] **TLS correct** — one SAN certificate covering all eight names
- [ ] The **same** certificate served by mail1 and mail2 (proves cluster distribution)
- [ ] ACME challenge type is DNS-01
- [ ] TLS 1.0 and 1.1 disabled on every listener
- [ ] Renewal verified at day 30

## Mail flow
- [ ] **SMTP inbound works** — external message delivered to a real mailbox via MX 10, MX 20 **and MX 30**
- [ ] Inbound TCP 25 to mail3 verified **from outside your network**, not just from mail1/mail2
- [ ] **SMTP outbound works** — message delivered to Gmail with SPF/DKIM/DMARC pass
- [ ] **IMAP works** — login, folder list, message fetch over 993
- [ ] JMAP session endpoint responds
- [ ] **Unknown recipients rejected at RCPT** with 550, not accepted and bounced
- [ ] **Open relay test FAILS on both mail1 and mail2** ← if this passes, stop everything
- [ ] Authenticated submission succeeds on 465

## Security
- [ ] Admin password is 20+ random characters
- [ ] **TOTP enabled on every admin account**
- [ ] A second break-glass admin exists
- [ ] Admin accounts have no IMAP/JMAP/WebDAV access
- [ ] Auto-ban enabled, your own IPs allowlisted
- [ ] Per-user outbound rate limits set
- [ ] Per-user quotas set (nobody unlimited)
- [ ] SSH key-only; password auth disabled
- [ ] Firewall: 3900/3902/3903/5432/7447/3901 **never** open to 0.0.0.0/0
- [ ] Garage master admin token unused; scoped token in use for monitoring

## Operations
- [ ] **S3 works** — verified cross-node
- [ ] **Node failure tested** — TESTs 1, 1b, 1c, 2, 3, 7 all pass
- [ ] **Database failure tested** — TEST 8, including a real promote
- [ ] Inter-node latency measured and the failover target written down (2.9)
- [ ] Alerting fires when the PostgreSQL primary stops answering
- [ ] **Backup tested** — a bundle produced, decrypted, and **restored to a throwaway VM**
- [ ] Backups shipping off-box on a schedule
- [ ] `BACKUP_PASSPHRASE` stored in a password manager, not only in `.env`
- [ ] Off-site blob copy configured
- [ ] Monitoring alerts on disk, queue depth, replication lag, cert expiry, Garage health
- [ ] External blacklist monitoring on both sending IPs
- [ ] Calendar reminder at day 30 to confirm certificate renewal
- [ ] Quarterly restore rehearsal on the calendar

---

## Things you didn't ask about that will bite you anyway

1. **Outbound IP reputation is earned, not configured.** Three brand-new sending IPs have no history — and the Frontier one has *less* than none, because receivers apply extra scepticism to non-datacenter address space. Send a handful of messages a day for the first week, then dozens, then hundreds. Blasting a mailing list on day one gets you throttled by Gmail and Microsoft for months. Warm one IP at a time, not all three at once.
2. **Microsoft is its own ecosystem.** Outlook/Hotmail/Live routinely defer new senders regardless of perfect authentication. Enrol in the Microsoft SNDS and JMRP programmes once you're sending.
3. **Feedback loops.** Register with Yahoo/AOL's FBL and Microsoft JMRP so you learn when recipients mark your mail as spam.
4. **A subscription-model catch:** `p=reject` DMARC breaks traditional mailing lists that rewrite nothing. If your users post to lists, expect complaints after the ramp.
5. **Postgres autovacuum on a mail workload.** High-churn tables (flags, changelogs) bloat. Watch `pg_stat_user_tables.n_dead_tup` and don't be surprised if you need to tune `autovacuum_vacuum_scale_factor` down on the busiest tables.
6. **LMDB and power loss.** Garage's own known-issues page documents metadata corruption after unclean shutdowns. `metadata_fsync = true` mitigates it; a UPS on the on-prem box would help more.
7. **Let's Encrypt rate limits during setup.** Five failed validations per hour. Use the staging directory while you're getting DNS-01 working.
8. **`swaks` from the server tests the server, not the internet.** Always finish with a test from outside — a real message to Gmail, read via *Show original*.
9. **Your `.env` is the crown jewels.** It contains the RPC secret, the database password, the S3 keys and the admin password. It is inside the backup that it decrypts. Keep the passphrase somewhere else.
10. **A 50 GB disk with 30 GB reserved for Garage is genuinely tight.** Set the disk alert at 80%, not 90%, and mean it. If you can attach a block-storage volume to each Linode for `/var/lib/garage`, do it before you have real mail to migrate.
