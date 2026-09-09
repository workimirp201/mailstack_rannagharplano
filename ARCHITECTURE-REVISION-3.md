# Architecture revision 3 — automated failover
### rannagharplano.com · 8 September 2026

**Your three answers, applied:**

| You said | Applied as |
|---|---|
| "172.104.58.45 Its the IP" | ✅ Singapore IP fixed everywhere. No unresolved IP questions remain |
| "please make do with 50GB" | ✅ No block storage. `GARAGE_CAPACITY=18G`, bucket quota 15 GiB, ~18 GB usable S3. Full arithmetic in §6 |
| "we need an automated failover… if it takes 5–10 mins, no issues. but it has to be automated" | ✅ etcd + Patroni + HAProxy + a DNS-claiming promotion callback. Measured budget ≈ **3.5 minutes worst case**. §1–§5 |

---

# 1. What automated failover actually requires

A database that promotes itself is only a third of the problem. Three things have to move, and if any one of them stays put you still have an outage:

| # | What must move | Without it | Solved by |
|---|---|---|---|
| 1 | **A standby must become primary** | Nothing is writable | **Patroni**, using **etcd** to decide who holds the leader lock |
| 2 | **Stalwart and Roundcube must reconnect to the new primary** | Every node keeps talking to a dead host | **HAProxy** on each node, checking Patroni's REST API |
| 3 | **Clients must reach a live node** | Users pointed at the dead node are stranded | **A promotion callback** that rewrites `mail.`, `webmail.` and `db.` to the new leader |

Revision 2 solved none of these automatically. Revision 3 solves all three, with no human in the loop.

```
                       ┌──────────── etcd (3 members, one per site, mTLS) ────────────┐
                       │   holds ONE leader lock. quorum = 2 of 3.                    │
                       └───▲──────────────────▲──────────────────▲────────────────────┘
                           │                  │                  │
                     ┌─────┴─────┐      ┌─────┴─────┐      ┌─────┴─────┐
                     │ Patroni   │      │ Patroni   │      │ Patroni   │
                     │  mail1    │      │  mail2    │      │  mail3    │
                     │ PostgreSQL│      │PostgreSQL │      │PostgreSQL │
                     │  standby  │      │ ★ LEADER ★│      │  standby  │
                     └─────▲─────┘      └─────▲─────┘      └─────▲─────┘
                           │                  │                  │
                           └──────────┬───────┴──────────┬───────┘
                                      │  GET /primary → 200 only on the leader
                     ┌────────────────┴─────────────────┐
                     │  HAProxy on EVERY node            │
                     │  127.0.0.1:5433 → current primary │
                     └────────────────┬─────────────────┘
                                      │
                  ┌───────────────────┼───────────────────┐
                  │                   │                   │
             Stalwart            Roundcube            pg_dump / psql
         (config.json)        (db_dsnw)              (backup.sh)

              ── on promotion, Patroni runs bin/patroni-callback.sh, which
                 repoints mail. / webmail. / db. at the new leader (TTL 60)
```

**The key move is HAProxy.** Stalwart's `config.json` no longer names a host at all — it says `127.0.0.1:5433`. That address is correct on every node, forever, whichever node is primary. No DNS wait, no restart, no reconfiguration. Failover becomes invisible to the application.

---

# 2. The failover timeline

Worst case: mail2 (the leader) is hard-powered-off at T+0.

| T | What happens | Driven by |
|---|---|---|
| 0 s | mail2 dies. Its leader lock stops being renewed | — |
| 0–120 s | mail1 and mail3 wait out the lock TTL. **A blip shorter than this changes nothing** — this is the anti-flapping window | `PATRONI_TTL=120` |
| ~120 s | Lock expires. The healthier standby (lowest lag, `nosync` and `maximum_lag_on_failover` respected) takes it | Patroni leader race |
| ~125 s | `pg_promote()`. PostgreSQL is writable | Patroni |
| ~128 s | Every node's HAProxy sees `GET /primary` → 200 on the new leader and 503 on the old, and switches. **Stalwart and Roundcube on the two surviving nodes resume here** | HAProxy `inter 3s rise 2` |
| ~130 s | The promoted node's callback rewrites `mail.`, `webmail.`, `db.` to itself | `patroni-callback.sh` |
| 130–190 s | Clients still cached on the old IP expire and re-resolve | DNS TTL 60 |
| **≈ 3.5 min** | **Fully recovered** | |

**Two different user experiences, worth knowing apart:**

- Someone connected to a **surviving** node (mail1 or mail3) sees a ~2-minute interruption and then everything works. They never needed DNS.
- Someone connected to **mail2** waits for DNS as well — call it 3.5 minutes.
- **Inbound mail loses nothing at any point.** Sending servers get `4xx` and retry; their normal schedule is 15 min → 1 h → 4 h.

Your budget was 5–10 minutes. This fits with room to spare, and the room is deliberate — see §3.

## Tuning it faster (and why I didn't)

`PATRONI_TTL` is the dial. At 120 s a two-minute network wobble between Singapore and Dallas is absorbed silently. Drop it to 30 (Patroni's default) and you failover in about a minute — and you also failover every time the Pacific link hiccups for 35 seconds, which over a WAN is a routine event. A spurious failover costs you a promotion, a rewind, and a rebuild of the old primary. **Since you told me 5–10 minutes is fine, I spent that budget on stability rather than speed.** Change `PATRONI_TTL` in `.env` if you want it different; Patroni enforces `loop_wait + 2×retry_timeout ≤ ttl` and the script keeps you inside it.

---

# 3. The new failure mode you are buying — read this one carefully

Automation is not free, and the price is specific and worth stating plainly.

**With manual failover, losing two nodes was survivable.** One node left alive, you promote it by hand, service continues degraded.

**With etcd, losing two nodes is a full outage.** etcd needs a quorum of 2 of 3 to elect anything. With one member left there is no quorum, so no leader lock can be held. Patroni does the correct-but-painful thing: it **demotes** the surviving primary rather than risk two primaries existing. Everything goes read-only until you intervene.

| Nodes lost | Manual failover (rev 2) | Automated failover (rev 3) |
|---|---|---|
| 1 (any) | outage until a human acts | ✅ **~3.5 min, no human** |
| 2 | a human can promote the survivor | ❌ **outage until a human breaks quorum by hand** |
| Split brain | impossible (one writable DB) | impossible (leader lock + watchdog) |

**This is a good trade for you** — losing one node is the common case and it is now handled at 3 a.m. without you; losing two of three sites simultaneously is rare. But it is a real regression in the two-node-loss case and you should know it exists rather than discover it.

**Recovery from quorum loss** (keep this where you can find it without a working mail server):

```bash
# On the ONE surviving node, after confirming the other two are genuinely gone.
sudo systemctl stop patroni etcd
sudo -u etcd cp -a /var/lib/etcd /var/lib/etcd.bak-$(date +%s)

sudo -u etcd /usr/local/bin/etcd \
  --name "$(hostname -s)" \
  --data-dir /var/lib/etcd \
  --force-new-cluster \
  --listen-client-urls https://0.0.0.0:2379 \
  --advertise-client-urls "https://$(curl -s https://api.ipify.org):2379" \
  --cert-file /etc/mailstack/tls/node.crt --key-file /etc/mailstack/tls/node.key \
  --trusted-ca-file /etc/mailstack/tls/ca.crt --client-cert-auth &

# Confirm a single-member cluster is healthy, then restart normally and start Patroni.
etcdctl member list -w table
sudo systemctl start etcd patroni
patronictl -c /etc/patroni/patroni.yml list
```

When the other nodes come back: `etcdctl member add` each one and restart their etcd with `ETCD_INITIAL_CLUSTER_STATE=existing`.

## Why not avoid etcd entirely?

I considered the alternatives before adding a consensus store to a WAN:

| Option | Why not |
|---|---|
| **repmgr + repmgrd** | No DCS to run, which is genuinely appealing. But its split-brain protection is weaker, and it gives HAProxy no clean "who is primary" endpoint — you end up writing a custom health-check script, which is exactly the kind of bespoke HA code that fails at 3 a.m. |
| **pg_auto_failover** | Needs a monitor node. That monitor is a single point of failure, so you have automated failover that stops working when one specific box dies |
| **Patroni with its built-in Raft** | Removes etcd, but it is the least-used Patroni DCS and the least likely to behave predictably over a 200 ms link |
| **Patroni + etcd** | ✅ The standard. Every part is well-trodden, and `GET /primary` gives HAProxy a definitive answer with no custom code |

etcd's own docs cover exactly this deployment shape: heartbeat ≈ 0.5–1.5× max RTT, election ≥ 10× RTT, *"5s is a safe upper limit of global round-trip time"*. We use **250 ms / 5000 ms** against a ~200 ms Pacific link — conservative on both counts.

---

# 4. Consequences you need to accept

## 4.1 Webmail now runs on all three nodes

Revision 2 chose Option A (mail2 only) and the reasoning was sound *at the time*: webmail could not outlive the database primary anyway.

**Automation changes that.** The database now survives losing mail2, so webmail is the only thing that would still need a human — which contradicts "I don't want to manually do anything". So webmail is installed on all three nodes, and `webmail.rannagharplano.com` follows the promoted leader.

I am flagging this because it is a real cost: **three PHP stacks to patch instead of one**, on the component with the largest attack surface. `deploy.sh webmail` is idempotent and `bin/verify.sh` now reports the installed Roundcube version against the latest upstream release on every node, so at least you will know when you are behind.

They are not three independent webmails: all three share one `roundcube` database through their local HAProxy, so a user's preferences, signature and contacts are identical wherever they land.

## 4.2 Certificates for webmail move to DNS-01

`webmail.rannagharplano.com` only ever resolves to **one** node, but all three need a valid certificate for it so any of them can take the endpoint over. HTTP-01 can only ever validate on the node the name currently points at, so it cannot work for the other two. Every node therefore issues its own certificate for that name via **certbot DNS-01**, using the DNS token already in `.env`.

Three nodes renewing the same name would race on the `_acme-challenge` TXT record, so the script staggers the renewal timers (03:07, 03:27, 03:47) with a ten-minute jitter.

Stalwart's own certificate is unchanged: its internal ACME, DNS-01, stored in the shared data store, distributed to all three nodes.

## 4.3 PostgreSQL is now reachable on all three nodes

Any node can be primary, so TCP 5432 must be open **between all three**, not just inbound to mail2. Same for the Patroni REST port. §7 has the full table.

## 4.4 If your nginx lacks `ssl_preread`

Port 443 is shared between webmail and Stalwart by SNI routing in nginx's `stream` module. `deploy.sh webmail` checks for the module and **stops with a clear message** rather than half-installing. If Ubuntu's `libnginx-mod-stream` doesn't provide `ssl_preread` on your build, the same job is done by HAProxy:

```haproxy
frontend https_sni
    bind 0.0.0.0:443
    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }
    use_backend webmail_be  if { req_ssl_sni -i webmail.rannagharplano.com }
    default_backend stalwart_be

backend webmail_be
    mode tcp
    server rc 127.0.0.1:10444 send-proxy

backend stalwart_be
    mode tcp
    server sw 127.0.0.1:10443 send-proxy
```

Same result, same PROXY-protocol handling. HAProxy is already installed for the database, so this costs nothing extra.

## 4.5 mail3's relay needs two targets

mail3 relays outbound through another node (because Frontier's rDNS is generic). If it relayed only through mail2, then when mail2 died — exactly when mail3 might be promoted and serving users — outbound mail would fail.

So mail3 relays to **`smtp-relay.rannagharplano.com`**, an A record holding **both** mail1 and mail2. Multiple A records are safe here in a way they are not for client access: an MTA that fails to connect tries the next address, which is precisely what SMTP is specified to do. That is the same reason MX priorities are real failover while round-robin IMAP is not.

## 4.6 One manual step remains during installation

Stalwart's HTTPS listener has to move to `127.0.0.1:10443` and trust the PROXY protocol from loopback, so nginx can SNI-route port 443. That is a WebUI change (**Settings → Server → Listeners**, and `proxyTrustedNetworks` → `127.0.0.0/8` in **Settings → Network → Services**), because that configuration lives in Stalwart's settings database, not in a file. `deploy.sh stalwart` prints the reminder; `bin/verify.sh` checks it afterwards.

---

# 5. Synchronous replication — one decision left, and it depends on a number you have not measured

Default is **asynchronous** (`PG_SYNCHRONOUS_MODE=off`). An automatic failover can then lose the last fraction of a second of WAL — in mail terms, a message that was accepted but not yet replicated. `PATRONI_MAX_LAG=1048576` stops Patroni promoting any standby more than 1 MiB behind.

**If `ping mail3` from mail2 is under about 40 ms**, set `PG_SYNCHRONOUS_MODE=on` and you get **zero-data-loss failover**. The scripts already tag mail1 `nosync: true`, so Singapore can never be chosen as the synchronous standby and no commit ever waits on the Pacific. `synchronous_mode_strict` is left `false` deliberately: if the sync standby dies, Patroni degrades to async rather than blocking every write.

```bash
# on mail2
ping -c 20 47.190.50.190
```

| Result | Setting |
|---|---|
| **< 40 ms** | `PG_SYNCHRONOUS_MODE=on` — commits wait on a nearby node, no data loss on failover |
| 40–150 ms | `off`, unless you would rather pay that latency on every write |
| > 150 ms | `off` |

`./deploy.sh preflight` now prints inter-node RTT so you get the number without thinking about it.

---

# 6. Storage on 50 GB, with everything

No block storage. Per node — and the three nodes are now near-identical, since webmail runs everywhere:

| Item | Size | Note |
|---|---|---|
| OS + packages | 6 GB | Ubuntu 24.04 plus upgrade headroom |
| **Garage data** | **20 GB** | declared capacity 18G leaves 2 GB of slack |
| Garage metadata (LMDB) | 3 GB | |
| Garage snapshots | 2 GB | 6-hourly, protects against LMDB corruption |
| PostgreSQL (`stalwart` + `roundcube`) | 6 GB | metadata only — message bodies live in Garage |
| Stalwart local state | 1 GB | |
| Webmail (nginx + PHP 8.3 + Roundcube + temp) | 1 GB | |
| etcd + Patroni + HAProxy | 0.5 GB | etcd is capped at 2 GB by `QUOTA_BACKEND_BYTES` and auto-compacts hourly |
| Logs + journal | 2 GB | journald capped at 1 GB |
| Backup staging | 3 GB | |
| **Free reserve** | **5.5 GB** | not spare — a full disk corrupts LMDB and stops PostgreSQL writes |
| **Total** | **50 GB** | |

**Result: ≈ 18 GB of usable, 3×-replicated S3.** Remember the arithmetic that surprises everyone: with `replication_factor = 3`, usable capacity equals **one** node's capacity, not the sum. 18 GB usable consumes 54 GB of raw disk across the cluster.

The bucket quota is set to **15 GiB** — below the 18 GB declared capacity on purpose, so Garage refuses writes before any node's disk gets tight. That quota is the only hard enforcement in the system; the declared capacity is an input to the placement algorithm, not a write-time limit.

**Alert at 75%, not 90%.** With 5.5 GB of reserve on a 50 GB disk you do not have room to react slowly.

---

# 7. Firewall ports — revised

`SG` = 172.104.58.45 · `US` = 104.237.138.198 · `OP` = 47.190.50.190. **Every "cluster" row is public-internet traffic between three specific addresses — restrict each rule to those three /32s.**

## Public

| Port | Proto | Source | Destination | Purpose |
|---|---|---|---|---|
| 25 | TCP | `0.0.0.0/0` | mail1, mail2 | Inbound SMTP (MX 10 / MX 20). **Not mail3** — no MX 30 |
| 25 | TCP | mail1, mail2 | `0.0.0.0/0` | Outbound delivery. mail3 relays instead |
| 465 | TCP | `0.0.0.0/0` | **all three** | Submission, implicit TLS. Any node may hold `mail.` |
| 993 | TCP | `0.0.0.0/0` | **all three** | IMAP, implicit TLS. Same reason |
| 443 | TCP | `0.0.0.0/0` | **all three** | nginx SNI → webmail or Stalwart (JMAP, WebDAV, `/admin`, autoconfig, MTA-STS) |
| 80 | TCP | `0.0.0.0/0` | all three | HTTPS redirect + ACME fallback |

Still closed: 110/995 (POP3), 143 (plaintext IMAP), 587 (STARTTLS submission), 4190 from the internet.

## Cluster / internal — restrict to the three IPs

| Port | Proto | Source | Destination | Purpose |
|---|---|---|---|---|
| **2379** | TCP | SG, US, OP | SG, US, OP | 🆕 **etcd client.** Patroni reads/writes the leader lock. mTLS + RBAC |
| **2380** | TCP | SG, US, OP | SG, US, OP | 🆕 **etcd peer.** Raft between members. mTLS |
| **8008** | TCP | SG, US, OP | SG, US, OP | 🆕 **Patroni REST.** HAProxy health checks. Basic-auth on write endpoints |
| **5432** | TCP | SG, US, OP | **SG, US, OP** | 🔶 **PostgreSQL — now all three.** Any node can be primary. TLS + scram only |
| 7447 | TCP | SG, US, OP | SG, US, OP | Stalwart Zenoh coordination |
| 3901 | TCP | SG, US, OP | SG, US, OP | Garage RPC |

> **Patroni's REST API can trigger a failover over HTTP.** The write endpoints are protected with basic auth by the generated config, but port 8008 must never be open to the internet. Same for 2379 — anyone who can write to etcd owns your cluster. mTLS and RBAC are the second and third layers; your allowlist is the first.

## Loopback only — must not be reachable from anywhere

| Port | Purpose |
|---|---|
| 5433 | HAProxy → current PostgreSQL primary |
| 7000 | HAProxy stats |
| 3900 / 3902 / 3903 | Garage S3 / web / admin |
| 10443 | Stalwart HTTPS behind the SNI front door |
| 10444 | Roundcube vhost behind the SNI front door |
| 4190 | ManageSieve, for Roundcube's filter UI |

## On-prem router forwards

TCP **2379, 2380, 8008, 5432, 7447, 3901** → the mail3 VM, plus **443, 465, 993, 80** so mail3 can serve clients when it holds the endpoint. **Not 25** — mail3 is not an MX.

---

# 8. DNS changes

Everything from revision 2 Configuration B stands. Three changes:

| Name | Type | Value | TTL | Change |
|---|---|---|---|---|
| `webmail` | A | 104.237.138.198 | **60** | 🆕 follows the leader automatically |
| `mail` | A | 104.237.138.198 | **60** | now rewritten by the promotion callback |
| `db` | A | 104.237.138.198 | **60** | now rewritten by the promotion callback |
| `smtp-relay` | A | 104.237.138.198 | 300 | 🆕 mail3's outbound relay target |
| `smtp-relay` | A | 172.104.58.45 | 300 | 🆕 second address, so the relay survives losing mail2 |

**Create all of them by hand once.** The callback *updates* existing records; it does not create them. If a record is missing it logs an error and carries on rather than failing the promotion — a DNS problem must never roll back a database promotion that already succeeded.

**Cloudflare users:** put your Zone ID in `CF_ZONE_ID` and scope the API token to **Zone → DNS → Edit on this zone only**. A global key on a mail server is a domain-takeover credential. Route 53 is also implemented; any other provider needs one function filled in — the file marks the spot.

MX stays **10 mail2, 20 mail1** with no MX 30, and mail3 stays out of SPF while its rDNS is generic.

---

# 9. Testing it — do this before real mail

## TEST A — the one that matters: kill the leader

```bash
# on whichever node patronictl shows as Leader
sudo systemctl stop patroni postgresql   # or: sudo poweroff, for the real thing
```

Then, from another node, watch it happen:

```bash
watch -n 5 'patronictl -c /etc/patroni/patroni.yml list'
```

**Expected:** old leader disappears → ~120 s of no leader → a standby takes the lock → `Leader | running`.

Confirm each layer moved:

```bash
# 1. the database is writable again through the local proxy
PGPASSWORD=... psql -h 127.0.0.1 -p 5433 -U stalwart -d stalwart -c "SELECT NOT pg_is_in_recovery();"
#    expect: t

# 2. HAProxy switched backends
curl -s 'http://127.0.0.1:7000/;csv' | awk -F, '/postgres_primary/{print $2, $18}'

# 3. the callback claimed the endpoints
sudo tail -20 /var/log/mailstack/dns-failover.log
dig +short mail.rannagharplano.com @1.1.1.1
dig +short webmail.rannagharplano.com @1.1.1.1

# 4. mail actually works
swaks --to you@rannagharplano.com --from test@example.com --server rannagharplano.com
curl -sI https://webmail.rannagharplano.com | head -1
```

**Time the whole thing.** If it is over 5 minutes, something is wrong — most likely DNS TTL or a callback error in that log.

## TEST B — bring the old leader back

```bash
sudo systemctl start patroni
patronictl -c /etc/patroni/patroni.yml list
```
It should rejoin as a **replica**, using `pg_rewind` if its timeline diverged. It must **not** come back as a second leader. If it does, stop everything and check etcd health — that is the one outcome that must never happen.

## TEST C — network partition, not a clean shutdown

From the Linode LISH console (not SSH — you will cut yourself off):
```bash
sudo ip link set eth0 down; sleep 400; sudo ip link set eth0 up
```
**Expected:** the same failover; the isolated node demotes itself because it cannot renew the lock. When it returns it rejoins as a replica. No split brain.

## TEST D — quorum loss (rehearse the painful one)

Stop etcd on two nodes. The survivor should go read-only within `ttl`. Then walk the recovery in §3 and time yourself. **Do this once, on purpose, while nothing is at stake.**

## TEST E — a blip must NOT cause a failover

```bash
sudo systemctl stop etcd && sleep 60 && sudo systemctl start etcd   # on the leader
```
**Expected: nothing.** 60 s is well inside the 120 s TTL. If this triggers a failover, your tuning is too aggressive.

---

# 10. What is still manual

Being honest about the boundary, since "automated" should mean something precise:

| Event | Automated? |
|---|---|
| One node fails (any of the three) | ✅ **Fully.** ~3.5 min |
| Database promotion | ✅ Patroni |
| Application reconnection | ✅ HAProxy |
| Client endpoint DNS | ✅ Promotion callback |
| Webmail availability | ✅ Runs on all three |
| Old primary rejoining after repair | ✅ Patroni + `pg_rewind` on start |
| Garage node returning | ✅ Automatic resync |
| **Two nodes lost simultaneously** | ❌ Manual quorum recovery — §3 |
| **Certificate renewal** | ✅ Both mechanisms, but **verify at day 30** |
| **Roundcube version upgrades** | ❌ It is a tarball. `verify.sh` tells you when you are behind |
| **Forgotten-password reset** | ❌ Admin action. No self-service flow exists |
| **A blocklisted sending IP** | ❌ Always a human problem |

---

# 11. Order of operations

```
mail2 :  ./deploy.sh gen-secrets
  ↓      scp .env to mail1 and mail3, change NODE_NAME only
all   :  ./deploy.sh preflight          ← read the RTT numbers, decide §5
all   :  ./deploy.sh prep
mail2 :  ./deploy.sh pki                ← scp the two printed bundles
1 & 3 :  ./deploy.sh pki-import /root/pki-mailN.tar.gz
all   :  ./deploy.sh garage
1 & 3 :  garage -c /etc/garage.toml node id
mail2 :  ./deploy.sh garage-cluster     ← paste S3 keys into .env on all three
all   :  ./deploy.sh etcd
mail2 :  ./deploy.sh etcd-auth          ← once all three are up
mail2 :  ./deploy.sh patroni            ← bootstraps the cluster
1 & 3 :  ./deploy.sh patroni            ← clone from the leader
all   :  ./deploy.sh haproxy
mail2 :  ./deploy.sh stalwart           ← then the setup wizard over an SSH tunnel
mail2 :  ./deploy.sh stalwart           ← again, to externalise the secrets
  ↓      WebUI: move HTTPS listener to 127.0.0.1:10443, trust 127.0.0.0/8
1 & 3 :  ./deploy.sh stalwart
all   :  ./deploy.sh webmail
all   :  ./deploy.sh verify
  ↓      then TESTS A–E in §9, before any real mail
```

Prerequisites unchanged from revision 2 §17: Linode port-25 ticket, Linode PTRs, the Frontier PTR request, the DNS API token and Zone ID, and the router forwards (now including 2379, 2380, 8008, 5432).

Still outstanding from last time, but neither blocks installation:
- **your exact Frontier /26** — only needed for the RFC 2317 ticket
- **confirmation that MX 10 + MX 20 with no MX 30 is what you want** — I have built it that way
