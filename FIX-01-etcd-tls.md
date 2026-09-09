# Fix 01 — etcd: TLS key permissions + client-cert-auth
### 9 September 2026 · applies to REVISION-3 bundles dated 8 Sep 2026

Two bugs in my `deploy.sh`. Both are fixed in the updated bundle; this file is
the recovery procedure for a cluster that already hit them.

---

## Bug 1 — `deploy.sh patroni` broke a running etcd

**Symptom**
```
{"level":"fatal","msg":"discovery failed",
 "error":"open /etc/mailstack/tls/node.key: permission denied"}
etcd.service: Scheduled restart job, restart counter is at 62.
```
…and `Connection refused` on port 2379 from every client.

**Cause.** `cmd_etcd` set `/etc/mailstack/tls/node.key` to `root:etcd 0640` so
the etcd service account could read it. `cmd_patroni` then called
`_pki_install` again, whose `install -m 0640` and `install -d -m 0750` reset
both the key **and the directory** back to `root:root`. etcd — running as user
`etcd` — instantly lost the ability to traverse the directory and open its own
private key, and crash-looped until systemd's rate limiter stopped it.

It only shows up on the node where you run the patroni phase, which is why
mail1 and mail3 stayed up and mail2 died.

**Fix in the new bundle.** A single idempotent `_tls_perms` helper now owns
these permissions and is called from *both* phases:

| Path | Owner | Mode | Why |
|---|---|---|---|
| `/etc/mailstack/tls` | `root:root` | `0755` | etcd **and** postgres must traverse it. A directory listing is not a secret |
| `ca.crt`, `node.crt` | `root:root` | `0644` | public |
| `node.key` | `root:etcd` | `0640` | the only secret; readable by etcd, nobody else |

`cmd_patroni` now also verifies the etcd user can still read the key and
restarts etcd if the phase disturbed it. `bin/verify.sh` checks it on every run.

---

## Bug 2 — client certificate auth is incompatible with Patroni

**Symptom**
```
Failed to get list of machines from https://<node>:2379/v3:
  <Unknown error: 'CommonName of client sending a request against gateway
   will be ignored and not used as expected', code: 2>
```

**Cause.** Patroni's `etcd3` driver talks to etcd's **HTTP/JSON gRPC-gateway**
(note the `/v3` path), not native gRPC. With `ETCD_CLIENT_CERT_AUTH=true`,
etcd derives the username from the client certificate's CommonName — but a
request arriving through the gateway carries the gateway's identity, not the
caller's. etcd refuses rather than authenticating as the wrong principal.
Our CNs are `mailN.rannagharplano.com`, which are not etcd users either.

This combination can never work. It is not a certificate problem and no CN
would fix it.

**Fix.** `ETCD_CLIENT_CERT_AUTH=false` on the **client** channel only.
`ETCD_PEER_CLIENT_CERT_AUTH=true` is unchanged — peers speak native gRPC to
each other, so mutual TLS works there and that is where it matters most.
Patroni's `etcd3` block now carries `cacert` only, no `cert`/`key`.

**Security after the change**

| Control | Before | After |
|---|---|---|
| Client traffic encrypted | ✅ | ✅ |
| Patroni verifies etcd's server certificate | ✅ | ✅ |
| Peer channel mutual TLS | ✅ | ✅ |
| Client authenticated by certificate CN | ✅ (but non-functional) | ❌ |
| Client authenticated by etcd RBAC | ✅ | ✅ user `patroni`, scoped to `/mailstack/` |
| Source restricted by firewall | ✅ | ✅ three /32s |

The net loss is a control that never worked. Authentication is now RBAC plus
your allowlist, which is the standard Patroni + etcd configuration.

---

## Recovery — for a cluster already in this state

### 1. On mail2 — stop Patroni flapping while you work
```bash
sudo systemctl stop patroni
```

### 2. On mail2 — repair the permissions and restart etcd
```bash
sudo chown root:root /etc/mailstack/tls
sudo chmod 0755     /etc/mailstack/tls
sudo chown root:etcd /etc/mailstack/tls/node.key
sudo chmod 0640      /etc/mailstack/tls/node.key
sudo chmod 0644      /etc/mailstack/tls/ca.crt /etc/mailstack/tls/node.crt

sudo -u etcd test -r /etc/mailstack/tls/node.key && echo "OK: etcd can read the key"

sudo systemctl reset-failed etcd
sudo systemctl restart etcd
systemctl status etcd --no-pager | head -5
```
`reset-failed` matters — the restart counter was at 62 and systemd will refuse
to start it again until the counter is cleared.

### 3. On mail1 and mail3 — turn off client certificate auth
```bash
grep ETCD_CLIENT_CERT_AUTH /etc/default/etcd
sudo sed -i 's/^ETCD_CLIENT_CERT_AUTH=true$/ETCD_CLIENT_CERT_AUTH=false/' /etc/default/etcd
grep ETCD_CLIENT_CERT_AUTH /etc/default/etcd     # must print: false
sudo systemctl restart etcd
```
mail2's journal already shows `false`, so it needs only the permission fix.

### 4. From any node — confirm quorum
```bash
ETCDCTL_API=3 etcdctl \
  --endpoints=https://172.104.58.45:2379,https://104.237.138.198:2379,https://47.190.50.190:2379 \
  --cacert=/etc/mailstack/tls/ca.crt \
  endpoint health --cluster -w table
```
All three must report healthy. Two out of three is quorum, but fix the third
before continuing.

### 5. Deploy the updated bundle, then carry on
```bash
# on all three, replacing the old files
cd /opt/mailstack
sudo ./deploy.sh fix-tls-perms      # idempotent; safe to run anywhere, any time

# mail2 only
sudo ./deploy.sh etcd-auth          # creates the RBAC users, enables auth, self-tests

# mail2 first, then mail1, then mail3
sudo ./deploy.sh patroni
patronictl -c /etc/patroni/patroni.yml list
```

`deploy.sh patroni` now refuses to run unless at least 2 of 3 etcd endpoints
are healthy **and** the `patroni` RBAC user can write to `/mailstack/`. You
will get a clear error instead of a silent loop.

---

## New commands in the updated bundle

| Command | What it does |
|---|---|
| `./deploy.sh fix-tls-perms` | Repairs `/etc/mailstack/tls` ownership and restarts etcd. Safe any time |
| `./deploy.sh etcd-reset` | Wipes a half-bootstrapped etcd member and restarts it. **Refuses** once Patroni has written cluster state |
| `./deploy.sh etcd-auth` | Now idempotent, creates the `root` role grant, and self-tests the `patroni` user |

## Also hardened in the etcd unit

`Type=notify` with the default 90 s start timeout would have killed etcd
during a first bootstrap while it waited for peers that were minutes away.
The unit now sets `TimeoutStartSec=0`, `Restart=always` and
`StartLimitIntervalSec=0`, and `deploy.sh etcd` treats `activating` as success
rather than failure — because on the first node, waiting for peers *is* the
correct state.

---

# Bug 3 — PGDG repository key stored armoured

**Symptom**
```
Err:4 https://apt.postgresql.org/pub/repos/apt noble-pgdg InRelease
  Unknown error executing apt-key
E: The repository '...noble-pgdg InRelease' is not signed.
```

**Cause.** I wrote the signing key to `apt.postgresql.org.asc` (ASCII armoured)
and pointed `signed-by=` at it. apt then falls back to `apt-key`, which is
deprecated and fails with that opaque message.

**Fix — this is exactly what you did, and it is now in the script:**
```bash
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  | gpg --dearmor -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg] \
https://apt.postgresql.org/pub/repos/apt noble-pgdg main" \
  > /etc/apt/sources.list.d/pgdg.list
apt update
```

The new `_pgdg_repo` helper in `deploy.sh` does this properly: installs `gnupg`
if missing, removes any stale `.asc`, dearmours to `.gpg`, derives the release
codename from `/etc/os-release` instead of hard-coding `noble`, verifies the
keyring is non-empty, and fails loudly if `apt-get update` still errors instead
of continuing to a confusing package-not-found later.

Your manual workaround and the script's version produce an identical result —
nothing to undo.
