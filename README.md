# Nutanix DR Automation — Step-by-Step Deployment Guide (AlmaLinux 9)

Monitors the HQ Nutanix cluster, automatically triggers the configured
recovery plan (FAILOVER) via the Nutanix v3 API once HQ is confirmed down,
and shows a live web dashboard with failover history and an animated
HQ → DR migration diagram.

Two systemd services share one SQLite database:
- `nutanix-dr-monitor` — health-check + failover-trigger loop
- `nutanix-dr-web` — the Flask/Gunicorn dashboard

They're kept separate on purpose: the trigger logic keeps running even if
you restart the web dashboard, and vice versa. If you only run one, run
the monitor — losing the dashboard temporarily doesn't stop protection;
losing the monitor does.

**Read this top to bottom once before running anything.** Each step
explains *why* it matters, not just what to type, so that when something
doesn't match the expected output you know what actually broke.

---

## Step 0 — Rotate credentials

**Why this matters:** any credential that's been pasted into a chat, a
shared doc, a ticket, or committed to a repo should be treated as
permanently public, regardless of who currently has access to where it
was pasted. This isn't paranoia specific to you — it's the standard
assumption in credential hygiene, because you can't fully audit every
place a piece of text might have been logged, cached, or synced.

1. Log into Prism Central → **Administration → Local User Management**
   (or **Role Mapping** if you're using directory-integrated auth).
2. Create a new service account, e.g. `dr-automation-svc`. Give it the
   narrowest role that works:
   - Read access to cluster/host status (for health awareness, though
     this app checks TCP reachability rather than calling this API)
   - Execute permission on Recovery Plans specifically — Nutanix's
     built-in roles include one scoped to DR operations; avoid granting
     full cluster-admin just for this.
3. Rotate the password on any account that appeared in the exposed
   material, even if you're not reusing it here.
4. Note the new username/password somewhere temporary (a password
   manager, not a text file) — you'll paste them into `.env` in Step 5,
   after which they live only in that one 600-permission file.

**Verify:** log into the Prism Central UI with the new account in an
incognito/private browser window. Confirm it can see Recovery Plans but
can't, say, delete a VM or modify cluster networking. If your Nutanix
version supports it, check **Administration → Audit** after a test login
to confirm the account's actions are logged separately from `admin`'s —
useful later if you ever need to trace what the automation did versus
what a human did.

**Common mistake:** creating the account but leaving `PC_API_VERIFY_SSL`
on for a self-signed cert without importing that cert anywhere — see
Step 5's note on `PC_API_VERIFY_SSL` for why this project defaults it to
`false` and what to do if you want it `true`.

---

## Step 1 — Get the code onto the server

**Why this matters:** the deployment steps below assume the project
directory is sitting on the server's local disk under `/tmp` (or
wherever you place it) before `install.sh` or the manual steps copy it
into `/opt`. There's no requirement it comes via `scp` specifically —
that's just the most universal method regardless of your OS.

On your workstation:

```bash
scp nutanix-dr-automation.zip youruser@YOUR_SERVER_IP:/tmp/
```

- `youruser` should be an account that already has SSH key or password
  access to the server — not root directly, if your organization's
  policy discourages direct root SSH (most do).
- If SSH is on a non-default port: add `-P 2222` (capital P) to the
  `scp` command with your actual port number.
- On Windows, WinSCP or `pscp.exe` (PuTTY's scp) do the same job with a
  GUI or CLI respectively.
- If you don't have direct SSH access but do have a private Git
  repository, `git clone` on the server is a fine substitute for the
  zip+scp dance — just make sure `.env` is in `.gitignore` so secrets
  never get committed.

On the server:

```bash
ssh youruser@YOUR_SERVER_IP
sudo dnf install -y unzip
cd /tmp
unzip nutanix-dr-automation.zip
cd nutanix-dr-automation
ls
```

**Verify:** the `ls` output shows `app/`, `systemd/`, `install.sh`,
`requirements.txt`, `.env.example`, `README.md`, `run_web.py`,
`run_monitor.py`. If `unzip` isn't found even after `dnf install`, check
you have working package repos (`dnf repolist`) — AlmaLinux minimal
installs sometimes need `dnf config-manager --set-enabled crb` or
similar depending on your mirror setup.

**Cleanup reminder:** once the code is copied into `/opt` in Step 4 (or
by `install.sh`), delete the copy in `/tmp` — `rm -rf /tmp/nutanix-dr-automation.zip /tmp/nutanix-dr-automation`
— so you don't have a second, less-protected copy of the code (and later,
potentially, of `.env`) sitting around.

---

## Step 2 — Choose: automated or manual install

**Why offer both:** `install.sh` is idempotent and safe to re-run, and
it's the fastest path to a working deployment. But if this is the first
time your team is running this kind of service on AlmaLinux, walking the
manual steps once builds the operational knowledge you'll want during a
real incident at 3 AM — you don't want the first time you learn how the
systemd units work to be while debugging a live DR event.

### Option A — Automated

```bash
sudo bash install.sh
```

Internally this runs, in order: `dnf install` of prerequisites, service
user creation, `rsync` of the code into `/opt/nutanix-dr-automation`
(excluding any existing `.env` or `state.db` so re-runs don't destroy
your config or history), venv creation, `pip install`, seeding `.env`
only if it doesn't already exist, and installing + enabling (but not
starting) both systemd units.

Expected final output block:
```
==================================================================
 Install steps complete. Services are ENABLED but NOT started yet.
==================================================================
```

If you use this option, **skip to Step 5** — Steps 3–4 below describe
what the script just did for you, for reference.

### Option B — Manual, step by step

Do Steps 3 and 4 below yourself. Functionally identical result.

---

## Step 3 — Install prerequisites, create the service user (manual path)

**Why a dedicated user:** running the monitor or web service as `root`
means a bug or a compromised dependency has full system access. Running
as an unprivileged, `nologin` system account means the blast radius of
anything going wrong is limited to what that account can touch — which,
per the systemd hardening directives in the `.service` files
(`ProtectSystem=strict`, `ProtectHome=true`), is essentially just
`/var/lib/nutanix-dr` and `/var/log/nutanix-dr`.

```bash
sudo dnf install -y python3.11 python3.11-pip git firewalld rsync
sudo systemctl enable --now firewalld
```

- `git` isn't strictly required if you transferred via `scp`/zip, but
  it's included in case you prefer cloning updates later.
- `firewalld` ships enabled on most AlmaLinux images already; the
  `enable --now` is a no-op if so.
- Note there's no separate `python3.11-venv` package on AlmaLinux/RHEL —
  unlike Debian/Ubuntu, the `venv` module is bundled directly into the
  `python3.11` package itself. `python3.11-pip` **is** a separate
  package though, and is needed for `python3.11 -m venv` to succeed
  (it bootstraps pip inside the new virtualenv via `ensurepip`).

**Verify:**
```bash
python3.11 --version
# Python 3.11.x
systemctl is-active firewalld
# active
```
If `python3.11` isn't found, check `dnf list available 'python3.11*'` —
some minimal AlmaLinux images need the AppStream repo enabled
(`dnf config-manager --set-enabled appstream`).

Create the service account:

```bash
sudo useradd --system --no-create-home --shell /sbin/nologin nutanix-dr
```

- `--system` allocates a UID below the normal user range (usually
  <1000) and skips creating a home directory or mail spool.
- `--shell /sbin/nologin` means nobody can interactively log in as this
  user even with valid credentials — it can only run what systemd tells
  it to run.

**Verify:**
```bash
id nutanix-dr
# uid=987(nutanix-dr) gid=983(nutanix-dr) groups=983(nutanix-dr)
```
(exact UID/GID numbers will differ — what matters is no "no such user"
error.)

Create directories:

```bash
sudo mkdir -p /opt/nutanix-dr-automation
sudo mkdir -p /etc/nutanix-dr
sudo mkdir -p /var/lib/nutanix-dr
sudo mkdir -p /var/log/nutanix-dr
sudo chown -R nutanix-dr:nutanix-dr /var/lib/nutanix-dr /var/log/nutanix-dr
```

Note `/opt/nutanix-dr-automation` and `/etc/nutanix-dr` are deliberately
**not** chowned yet here — `/opt` gets chowned after the code is copied
in Step 4, and `/etc/nutanix-dr` gets chowned after `.env` is created in
Step 5, so the ownership change happens on the final file/directory
contents, not an empty shell.

**Verify:**
```bash
ls -ld /opt/nutanix-dr-automation /etc/nutanix-dr /var/lib/nutanix-dr /var/log/nutanix-dr
```
The last two should show `nutanix-dr nutanix-dr` as owner:group.

---

## Step 4 — Deploy the code and install dependencies (manual path)

**Why a venv:** AlmaLinux's system Python is used by OS tooling (like
`dnf` itself in some versions). Installing Flask/requests/etc. into the
system Python risks version conflicts with OS packages. A virtualenv
isolates this app's dependencies completely.

```bash
sudo cp -r /tmp/nutanix-dr-automation/* /opt/nutanix-dr-automation/
cd /opt/nutanix-dr-automation
sudo python3.11 -m venv venv
sudo ./venv/bin/pip install --upgrade pip
sudo ./venv/bin/pip install -r requirements.txt
sudo chown -R nutanix-dr:nutanix-dr /opt/nutanix-dr-automation
```

The `chown -R` at the end is what makes the venv and all the `.py`
files owned by `nutanix-dr`, matching the `User=nutanix-dr` line in the
systemd units — if this step is skipped, the services will fail to
start with a permissions error.

**Verify:**
```bash
sudo -u nutanix-dr /opt/nutanix-dr-automation/venv/bin/python -c "import flask, requests, dotenv; print('OK')"
```
Should print `OK`. If you get `ModuleNotFoundError`, the `pip install`
step either failed silently (check for network/proxy issues reaching
PyPI) or ran against the wrong Python (double check you used
`./venv/bin/pip`, not a bare `pip`).

**No internet access from this server?** If the AlmaLinux box can't
reach PyPI directly, download the wheels for Flask, requests,
python-dotenv, and gunicorn (plus their dependencies) on a machine that
does have access, copy them over, and use
`pip install --no-index --find-links=/path/to/wheels -r requirements.txt`
instead.

---

## Step 5 — Configure secrets (`.env`)

**Why a single env file instead of hardcoding in `config.py`:** keeping
all secrets in one file that's excluded from the codebase means you can
safely share the code (for review, backup, or version control) without
also sharing credentials, and rotating a credential is a one-line edit
instead of a code change and redeploy.

If you used the automated install, `/etc/nutanix-dr/.env` already exists
(copied from `.env.example`, only if it didn't already exist — so a
second `install.sh` run won't clobber a `.env` you've already filled
in). If you did the manual path, create it now:

```bash
sudo cp /opt/nutanix-dr-automation/.env.example /etc/nutanix-dr/.env
```

Edit it:

```bash
sudo vi /etc/nutanix-dr/.env
```

| Variable | What to put | Why it matters |
|---|---|---|
| `HQ_HOST` | HQ cluster/Prism Element IP, e.g. `10.66.1.202` | This is the address the monitor's TCP check hits every cycle |
| `HQ_CHECK_PORT` | Usually `9440` (Prism's HTTPS port) | Confirm this is the port actually exposed for HQ's management plane |
| `HQ_CHECK_INTERVAL_SECONDS` | Default `30` | Lower = faster detection, more load; higher = slower detection, less noise |
| `HQ_FAILURE_THRESHOLD` | Default `5` | Total detection time ≈ interval × threshold. 30s × 5 = 2.5 min before any action — tune based on how tolerant you are of false positives vs. detection speed |
| `PC_API_HOST` | The Prism Central used to *run* the recovery plan — usually the DR-side PC, since it must be reachable when HQ is down | If you point this at the HQ-side PC instead, a real HQ outage will also take out your ability to trigger failover |
| `PC_API_USER` / `PC_API_PASSWORD` | The scoped account from Step 0 | Never the shared `admin` account |
| `PC_API_VERIFY_SSL` | `false` unless you've imported the PC's cert into the system trust store | Nutanix PCs commonly use self-signed certs by default (matching the `-k` flag in your original curl examples); set `true` only if you've deployed a proper CA-signed cert |
| `RECOVERY_PLAN_UUID` or `RECOVERY_PLAN_NAME` | Either the literal UUID, or the plan's display name | If both are blank, the monitor will error on every trigger attempt — set at least one |
| `FAILED_AVAILABILITY_ZONE_URL` | UUID of the HQ AZ | Get this from `availability_zones/list` (see the original reference doc) |
| `RECOVERY_AVAILABILITY_ZONE_URL` | UUID of the DR AZ | Same source |
| `FLASK_SECRET_KEY` | A random string | Used for Flask session signing; generate with `python3 -c "import secrets; print(secrets.token_hex(32))"` |
| `NOTIFY_WEBHOOK_URL` | Optional Slack/Teams incoming webhook | Leave blank to disable notifications entirely |

Lock down the file:

```bash
sudo chown nutanix-dr:nutanix-dr /etc/nutanix-dr/.env
sudo chmod 600 /etc/nutanix-dr/.env
```

**Verify:**
```bash
sudo -u nutanix-dr cat /etc/nutanix-dr/.env >/dev/null && echo "readable by service user: OK"
ls -l /etc/nutanix-dr/.env
# -rw------- 1 nutanix-dr nutanix-dr ... /etc/nutanix-dr/.env
```
If the permissions show anything other than `-rw-------` (600) with
`nutanix-dr` as both owner and group, re-run the `chown`/`chmod` above —
a file readable by other users defeats the purpose of moving secrets out
of the codebase.

---

## Step 6 — Test connectivity BEFORE starting the services

**Why test before starting systemd:** if you skip straight to starting
the services and something's misconfigured, you're debugging through
`journalctl` output, which is fine but slower than seeing the raw error
directly. Testing manually first isolates network problems from
application problems from systemd problems — three very different
failure modes that produce similar symptoms ("it's not working").

Test TCP reachability to HQ (what the monitor actually does):

```bash
timeout 5 bash -c "cat < /dev/null > /dev/tcp/10.66.1.202/9440" && echo "HQ reachable: OK" || echo "HQ NOT reachable"
```
Replace `10.66.1.202` with your real `HQ_HOST`. This uses bash's
built-in `/dev/tcp` pseudo-device to attempt a raw TCP connect — no
extra tools needed, and it's exactly what Python's `socket.create_connection()`
does under the hood in `nutanix_client.hq_cluster_reachable()`.

Test the Nutanix API itself with your new credentials:

```bash
curl -k -u 'dr-automation-svc:YOUR_NEW_PASSWORD' \
  -X POST https://10.66.2.235:9440/api/nutanix/v3/recovery_plans/list \
  -H "Content-Type: application/json" \
  -d '{"length": 5}'
```
Replace host and credentials with your real `PC_API_HOST` / `PC_API_USER` /
`PC_API_PASSWORD` values.

**Verify:** a JSON body with an `entities` array (even if empty). Specific
failure signatures to watch for:
- **`curl: (7) Failed to connect`** → network/firewall problem between
  this server and `PC_API_HOST` — check routing, firewalld, any
  intermediate firewalls, and that the AZ pairing between HQ and DR PCs
  is actually established.
- **`401 Unauthorized`** in the response → wrong username/password, or
  the account exists but isn't recognized by this specific PC (make sure
  you're hitting the PC where the account was actually created, not a
  different AZ's PC).
- **`403 Forbidden`** → credentials are valid but the account's role
  doesn't have permission to list recovery plans — go back to Prism
  Central and check the role assignment from Step 0.
- **Connects but hangs** → likely a one-way firewall rule (outbound
  allowed, but something's dropping the response) or an MTU/proxy issue;
  try `curl -v` for more detail on where it stalls.

Do not proceed to Step 7 until both checks above succeed — starting the
services with broken connectivity just means you'll be reading the same
errors in `journalctl` a few minutes later.

---

## Step 7 — Install and start the systemd services

**Why two separate services instead of one:** a crash or a `pip`
dependency issue in the web dashboard shouldn't stop the health-check
loop from protecting you, and restarting the web service to pick up a
UI tweak shouldn't have any chance of interrupting an in-progress
failover decision.

If you used `install.sh`, the units are already copied into
`/etc/systemd/system/` and `enable`d — just start them:

```bash
sudo systemctl start nutanix-dr-monitor
sudo systemctl start nutanix-dr-web
```

Manual path — install first:

```bash
sudo cp /opt/nutanix-dr-automation/systemd/nutanix-dr-monitor.service /etc/systemd/system/
sudo cp /opt/nutanix-dr-automation/systemd/nutanix-dr-web.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now nutanix-dr-monitor
sudo systemctl enable --now nutanix-dr-web
```

- `daemon-reload` tells systemd to re-read unit files from disk — always
  required after copying in new/changed `.service` files, or systemd
  will silently keep using its cached view of them.
- `enable` creates the symlinks so the services start automatically on
  boot; `--now` also starts them immediately in the same command.

**Verify:**
```bash
sudo systemctl status nutanix-dr-monitor nutanix-dr-web
```
Look for `Active: active (running)` in green on both. A status of
`activating (auto-restart)` repeating means the process is crash-looping
— check logs (below) before it burns through systemd's restart limit and
gives up.

Watch startup logs live:
```bash
sudo journalctl -u nutanix-dr-monitor -f
```
Expected first lines:
```
Monitor starting. Watching 10.66.1.202:9440 every 30.0s, threshold=5 consecutive failures.
```
Then a new line roughly every `HQ_CHECK_INTERVAL_SECONDS` as it checks.
`Ctrl+C` to stop following (this does not stop the service, just the
log view).

```bash
sudo journalctl -u nutanix-dr-web -f
```
Expected: gunicorn's boot log showing `2` workers started, no traceback.

**If a service won't start:** the single most common cause at this stage
is a typo in `.env` (e.g. `PC_API_HOST=` left blank) causing a Python
exception on import. `journalctl -u <service> -n 50 --no-pager` will show
the actual traceback — read the last few lines for the specific
`KeyError`, `ValueError`, or connection exception.

---

## Step 8 — Confirm the web dashboard is alive locally

**Why check locally before involving nginx:** if nginx is misconfigured,
you want to already know the Flask/gunicorn app itself is healthy so you
don't waste time debugging the wrong layer.

```bash
curl -I http://127.0.0.1:8080
```

**Verify:** `HTTP/1.1 200 OK` as the first line. If instead:
- **`Connection refused`** → the `nutanix-dr-web` service isn't actually
  running or isn't bound where expected — recheck `systemctl status` and
  `journalctl` from Step 7.
- **`curl: (7) Failed to connect to 127.0.0.1 port 8080`** → same as
  above, or `WEB_PORT` in `.env` doesn't match the port gunicorn was
  told to bind to in the `.service` file's `ExecStart` line — these must
  match (`8080` by default in both places as shipped).

Once you get `200 OK`, also load `http://127.0.0.1:8080/api/status` and
confirm it returns JSON — this exercises the SQLite read path, not just
that Flask is up.

---

## Step 9 — Expose the dashboard externally (nginx + basic auth)

**Why not just open port 8080 directly:** binding the web service to
`127.0.0.1` only, and requiring everything external to go through nginx,
means you get TLS termination, access logging, and authentication in one
well-understood place, instead of needing to build auth into the Flask
app itself. It also means a firewall rule change is the only thing
needed to change who can reach the dashboard, without touching the
Python service at all.

```bash
sudo dnf install -y nginx httpd-tools
sudo htpasswd -c /etc/nginx/.htpasswd youradminuser
```
`htpasswd -c` creates a new password file (the `-c` overwrites if it
already exists — omit `-c` when adding a second user later, e.g.
`sudo htpasswd /etc/nginx/.htpasswd anotheruser`).

Create `/etc/nginx/conf.d/nutanix-dr.conf`:

```nginx
server {
    listen 80;
    server_name dr-dashboard.yourdomain.local;

    auth_basic "Restricted";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```
Replace `dr-dashboard.yourdomain.local` with your actual internal DNS
name, or remove the `server_name` line to match on any hostname/IP.

Consider adding TLS (`listen 443 ssl;` with a cert) rather than plain
HTTP if the dashboard will ever cross a network segment you don't fully
trust — basic auth over plain HTTP sends credentials in a trivially
decodable (base64) form.

```bash
sudo nginx -t
sudo systemctl enable --now nginx
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --reload
```
`nginx -t` validates the config syntax *before* you reload/restart —
always run this after editing nginx config so a typo doesn't take down
an already-working nginx instance.

If SELinux blocks the proxy (AlmaLinux ships SELinux enforcing by
default):
```bash
sudo setsebool -P httpd_can_network_connect 1
```
You'll know this is the issue if `curl -I http://127.0.0.1` (through
nginx) returns a `502 Bad Gateway` even though `curl -I http://127.0.0.1:8080`
(direct to gunicorn) works fine — check `sudo ausearch -m avc -ts recent`
for the specific denial if `setsebool` alone doesn't resolve it.

**Verify:** from another machine on the LAN/VPN:
```bash
curl -I http://dr-dashboard.yourdomain.local
# HTTP/1.1 401 Unauthorized   <- correct, auth is being enforced
curl -I -u youradminuser:yourpassword http://dr-dashboard.yourdomain.local
# HTTP/1.1 200 OK
```

> `/api/reset` (clears the auto-trigger lock) has no authentication of
> its own at the Flask layer — this nginx basic-auth block is what
> actually protects it. Do not expose port 8080 directly to any network
> you don't fully trust without this in front of it.

---

## Step 10 — Restrict outbound firewall rules (optional hardening)

**Why bother if the server is already behind a firewall:** defense in
depth — if this specific host is ever compromised (via an unrelated
vulnerability, a bad dependency, whatever), a default-deny egress policy
limits what an attacker can reach *from* it, regardless of what other
network controls exist elsewhere.

The monitor host only genuinely needs outbound access to:
- `HQ_HOST:HQ_CHECK_PORT` (health checks)
- `PC_API_HOST:PC_API_PORT` (triggering/polling the recovery plan)
- Standard DNS/NTP if you're not using hardcoded IPs and don't already
  have time sync configured

If your environment runs a default-deny egress policy (via firewalld
rich rules, or an upstream network firewall/security group), scope
outbound rules to just those addresses/ports rather than leaving this
host with unrestricted outbound access.

**Verify:** after applying restrictive rules, re-run the two tests from
Step 6 to confirm they still pass — a firewall change that's too
aggressive will break the exact functionality you're trying to protect.

---

## Step 11 — End-to-end test (staging/maintenance window only)

**Why this step is separate and clearly marked:** everything up to here
verifies the pieces work in isolation. This step verifies the actual
failure-detection-to-failover pipeline works end to end — which is the
only way to have real confidence in a DR automation tool, but it also
means deliberately triggering the exact action this whole system exists
to perform. Treat it with the same care as a real DR test.

**Do this against a test/non-critical recovery plan, or during an
approved maintenance window on production — never as a surprise.**

1. Temporarily block the monitor host from reaching `HQ_HOST:HQ_CHECK_PORT` —
   options in order of preference: disconnect a test cluster's network
   cable, add a temporary firewalld rule
   (`sudo firewall-cmd --add-rich-rule='rule family="ipv4" destination address="10.66.1.202" port port="9440" protocol="tcp" reject'`),
   or simply power off a test cluster if that's what you're using for
   this drill.
2. Watch `sudo journalctl -u nutanix-dr-monitor -f` — you should see the
   consecutive-failure count increment on each check
   (`HQ check failed (1/5 consecutive).`, then `2/5`, etc.).
3. At the configured threshold, you'll see
   `HQ confirmed DOWN. Triggering failover for plan ...` followed by
   either a success line with a `job_uuid`, or an error if something in
   the trigger call itself failed (in which case the lock is NOT set,
   and it will retry on the next cycle — check the error message for
   what to fix).
4. Open the dashboard (`http://dr-dashboard.yourdomain.local`) — the
   status card should show red/DOWN, and the migration diagram should
   populate with VM markers transitioning from gray (pending) through
   orange (migrating) to green (completed) as the recovery job
   progresses.
5. Confirm in Prism Central directly that the recovery plan job you see
   in the dashboard matches what Nutanix itself reports — this cross-check
   matters the first time, to build confidence the dashboard's
   `get_job_status()` parsing (see note below) matches your specific
   AOS/PC version's response format.
6. Restore connectivity to the test HQ cluster, complete your normal
   Nutanix failback procedure, and once you've confirmed HQ is healthy
   again, click **"Reset monitor lock"** on the dashboard (or
   `curl -u user:pass -X POST http://dr-dashboard.yourdomain.local/api/reset`)
   so the monitor is armed for the next real event. Skipping this step
   means a genuine future outage will be detected and logged, but the
   automatic trigger will not fire again until the lock is cleared.

---

## How the failover decision works

- The monitor opens a TCP connection to `HQ_HOST:HQ_CHECK_PORT` every
  `HQ_CHECK_INTERVAL_SECONDS`.
- It needs `HQ_FAILURE_THRESHOLD` **consecutive** failures before acting
  — a single success resets the counter to zero, so intermittent
  flapping never accumulates toward the threshold.
- On confirmed failure, it calls `recovery_plan_jobs` (FAILOVER) exactly
  once, then locks itself (`failover_triggered=1` in the SQLite state
  table) so it will not fire again automatically, even if HQ stays down
  and further checks keep failing.
- Clear the lock from the dashboard only after failback/cleanup is
  confirmed complete.

### About the VM-level diagram data

`app/nutanix_client.get_job_status()` parses a per-VM `entity_list` out
of the `recovery_plan_jobs/{uuid}` response. The exact JSON shape can
differ across AOS/PC versions. If the dashboard only shows one generic
marker instead of per-VM icons, manually `curl` that endpoint for a real
job (`GET .../recovery_plan_jobs/<uuid>`) and compare its structure
against what `get_job_status()` expects — adjust the field names in that
one function; the `normalized` dict it returns is the only contract the
frontend JavaScript depends on.

---

## Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| `nutanix-dr-monitor` keeps restarting | Bad `.env` value, unreachable `PC_API_HOST`, or a Python exception on startup | `sudo journalctl -u nutanix-dr-monitor -n 50 --no-pager` |
| `curl -I http://127.0.0.1:8080` → connection refused | Web service crashed on startup or isn't running | `sudo journalctl -u nutanix-dr-web -n 50 --no-pager` |
| Health checks always fail even when HQ is up | Wrong `HQ_HOST`/`HQ_CHECK_PORT`, or a firewall between this host and HQ | Re-run Step 6's `/dev/tcp` test |
| `401 Unauthorized` from the Nutanix API | Wrong `PC_API_USER`/`PC_API_PASSWORD`, or hitting the wrong PC | Log into the Prism Central UI with the same credentials against the same host |
| `403 Forbidden` from the Nutanix API | Credentials valid but role lacks permission | Recheck role assignment in Prism Central (Step 0) |
| Recovery plan not found | `RECOVERY_PLAN_NAME` typo, or the plan lives on a different PC than `PC_API_HOST` | Re-run the `recovery_plans/list` call from Step 6 |
| Dashboard shows one generic marker instead of per-VM icons | API schema difference on your AOS/PC version | See "About the VM-level diagram data" above |
| nginx returns `502 Bad Gateway` | SELinux blocking the proxy connection | `sudo setsebool -P httpd_can_network_connect 1`, then `sudo ausearch -m avc -ts recent` if it persists |
| `Reset monitor lock` reachable by anyone on the LAN | nginx/auth not set up yet, or dashboard exposed on 8080 directly | Complete Step 9; never expose port 8080 without it |
| `FileNotFoundError: No usable temporary directory found` in gunicorn logs | `ProtectSystem=strict` makes `/tmp` read-only for the systemd-managed process (works fine when run manually, since your shell isn't restricted) | Add `PrivateTmp=true` to the `.service` file, `daemon-reload`, restart |
| Monitor never triggers even after HQ is confirmed down in logs | The lock from a previous test wasn't cleared | Click "Reset monitor lock" on the dashboard, or `POST /api/reset` |

---

## Extending

- **Notifications**: set `NOTIFY_WEBHOOK_URL` in `.env` to a Slack/Teams
  incoming webhook URL to get a message when a failover is triggered —
  no code changes needed, it's read at monitor startup.
- **Multiple HQ clusters**: this design assumes one HQ cluster and one
  recovery plan. For more, run one monitor process per HQ cluster, each
  with its own `.env` file and systemd unit (copy and rename
  `nutanix-dr-monitor.service`), all writing to the same SQLite database
  — each event row already carries the plan UUID, so the dashboard and
  history table naturally support multiple plans without changes.
- **Log rotation**: systemd's journal handles rotation automatically for
  anything logged via `journalctl`. If you set `LOG_PATH` in `.env` to
  write to a plain file instead, add a `logrotate` config for it under
  `/etc/logrotate.d/` so it doesn't grow unbounded.
