# mailstack — rannagharplano.com

3-node Stalwart mail system across Singapore (mail1), USA (mail2) and on-prem
(mail3), with **automated PostgreSQL failover** and **Roundcube webmail**.

## Read in this order

| File | What it is |
|---|---|
| **`ARCHITECTURE-REVISION-3.md`** | ⭐ **Current design.** Automated failover, webmail placement, revised ports and storage. Read this first |
| `ARCHITECTURE-REVISION-2.md` | Webmail choice and reasoning, the Frontier rDNS explanation, DNS Configurations A and B, the corrections to revision 1 |
| `RUNBOOK.md` | The long-form runbook: DNS records, GUI walkthrough, backups, monitoring, troubleshooting. **PARTs 5, 7, 8 and 16 are superseded by revision 3** where they conflict |

## Versions

| | |
|---|---|
| Stalwart Mail Server | v0.16.19 (24 Aug 2026) |
| Garage | v2.4.0 (6 Sep 2026) |
| PostgreSQL | 16 (PGDG) |
| Patroni | 4.x (PGDG) |
| etcd | v3.6.x |
| Roundcube | 1.7.4 (6 Sep 2026) |
| OS | Ubuntu 24.04 LTS, x86_64 |

## Layout

```
mailstack/
├── ARCHITECTURE-REVISION-3.md   ← current design
├── ARCHITECTURE-REVISION-2.md   ← webmail + Frontier rDNS + DNS plans
├── RUNBOOK.md                   ← long-form operations manual
├── env.example                  ← copy to .env, chmod 600, edit ONE line
├── deploy.sh                    ← the one command
├── lib/common.sh                ← env loading + permission enforcement
└── bin/
    ├── verify.sh                ← read-only health sweep
    ├── backup.sh                ← encrypted backup bundle
    └── patroni-callback.sh      ← claims mail./webmail./db. on promotion
```

## Install

```bash
sudo install -d -m 0755 /opt/mailstack
# copy this bundle to /opt/mailstack
cd /opt/mailstack
sudo cp env.example .env && sudo chmod 600 .env
sudo chmod +x deploy.sh bin/*.sh
```

## Order of operations

| # | Command | Where |
|---|---|---|
| 1 | `nano .env` — set `NODE_NAME`, check IPs | mail2 |
| 2 | `sudo ./deploy.sh gen-secrets` | **mail2 only** |
| 3 | copy `.env` to mail1 + mail3, change `NODE_NAME` | — |
| 4 | `sudo ./deploy.sh preflight` — **note the RTT numbers** | all three |
| 5 | `sudo ./deploy.sh prep` | all three |
| 6 | `sudo ./deploy.sh pki` → scp the printed bundles | **mail2 only** |
| 7 | `sudo ./deploy.sh pki-import /root/pki-mailN.tar.gz` | mail1, mail3 |
| 8 | `sudo ./deploy.sh garage` | all three |
| 9 | `sudo garage -c /etc/garage.toml node id` | mail1, mail3 |
| 10 | `sudo ./deploy.sh garage-cluster` → paste S3 keys into `.env` everywhere | **mail2 only** |
| 11 | `sudo ./deploy.sh etcd` | all three |
| 12 | `sudo ./deploy.sh etcd-auth` | **mail2 only**, once all three are up |
| 13 | `sudo ./deploy.sh patroni` | **mail2 first**, then mail1, mail3 |
| 14 | `sudo ./deploy.sh haproxy` | all three |
| 15 | `sudo ./deploy.sh stalwart` → setup wizard over an SSH tunnel | **mail2 first** |
| 16 | `sudo ./deploy.sh stalwart` again | mail2 |
| 17 | WebUI: move HTTPS listener to `127.0.0.1:10443`, trust `127.0.0.0/8` | browser |
| 18 | `sudo ./deploy.sh stalwart` | mail1, mail3 |
| 19 | `sudo ./deploy.sh webmail` | all three |
| 20 | `sudo ./deploy.sh verify` then TESTS A–E | all three |

## Day to day

```bash
sudo ./deploy.sh status                          # services + Patroni + Garage
sudo ./bin/verify.sh                             # full sweep, exit 0 = green
sudo ./bin/backup.sh                             # encrypted bundle
patronictl -c /etc/patroni/patroni.yml list      # who is the leader
sudo tail -f /var/log/mailstack/dns-failover.log # what the last promotion did
```

## If one node shuts down

| Node lost | Result |
|---|---|
| mail1 (Singapore) | ✅ Automatic. Senders use MX 10; nothing user-visible |
| mail3 (on-prem) | ✅ Automatic. Nothing user-visible |
| mail2 (USA) | ✅ **Automatic, ~3.5 min.** Patroni promotes, HAProxy switches, DNS follows. No mail lost |
| **Any two nodes** | ❌ etcd loses quorum → read-only until manual recovery. Procedure in REVISION-3 §3 |

## The five things most likely to bite you

1. **Outbound TCP 25 is blocked by Linode by default.** File the ticket before you build anything.
2. **Frontier must set reverse DNS for `47.190.50.190`** before mail3 may send. Until then it relays through `smtp-relay.rannagharplano.com`.
3. **Create `mail`, `webmail`, `db` and `smtp-relay` A records by hand first.** The failover callback updates records; it does not create them.
4. **Roundcube does not auto-update.** `verify.sh` compares your version against upstream on every run — act on it.
5. **Garage usable capacity equals ONE node's capacity**, not the sum, at `replication_factor = 3`. 18 GB usable from 50 GB disks.
