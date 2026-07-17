# Getting started

From blank SD card to live telemetry on your bench.

## 1. Prepare the Pi

- Flash **Raspberry Pi OS Lite 64-bit** (Debian bookworm) — Raspberry Pi Imager
  is fine. Any arm64/amd64 Debian bookworm box also works.
- Boot it, get it on your LAN (Ethernet recommended for the bench), and SSH in.
- Give it a memorable hostname (`sudo raspi-config` → System → Hostname, e.g.
  `bench`). You'll browse to `http://bench.local:8000` — the mDNS name survives
  DHCP lease changes; a raw IP doesn't.

## 2. Install the hub

```
curl -fsSL https://raw.githubusercontent.com/ezzatisawesome/guppi/main/install.sh | sudo bash
```

One command, ~2–4 minutes on a Pi. It installs PostgreSQL (a system service),
PostgREST, NATS, and the Guppi hub, and gives you one command — `guppi-hub` —
that runs all the Guppi servers in the foreground with their logs in your
terminal. Nothing runs as a hidden daemon.

```
guppi-hub                 # NATS + PostgREST + hub, logs live in the terminal
# Ctrl-C                  # stops all three
```

`guppi-hub` holds the terminal on purpose — you watch the live logs, and
Ctrl-C (or closing the terminal) stops everything. Nothing auto-starts,
including after a reboot: run `guppi-hub` again.

If you're on the Pi over SSH and want the bench to survive logging out, start
it inside a terminal multiplexer you install yourself:

```
sudo apt install tmux     # once
tmux new -s hub           # open a session
guppi-hub                 # start the bench inside it
# Ctrl-b, then d          # detach — leaves it running
tmux attach -t hub        # reattach later
```

While `guppi-hub` runs, open **`http://<hostname>.local:8000`** from any
browser on the LAN. No account, no login — the dashboard is just there.

Sanity check:

```
curl http://localhost:8000/health
# → {"status":"ok","mode":"local","postgres":"ok"}
```

## 3. Connect your instruments

On the machine physically wired to the instruments — the same Pi is the common
case:

```
sudo bash /opt/guppi/src/packages/rack/install.sh
guppi-rack
```

The rack installer asks which hub this rack should pair with:

```
Which agent should this rack pair with?
    1) Guppi Cloud   — https://app.guppidev.com   (hosted; default)
    2) This machine  — http://127.0.0.1:8000       (a hub running on this box)
    3) Custom URL    — a self-host agent on your LAN (e.g. http://bench.local:8000)
```

- **Same box as the hub** — if `guppi-hub` is already running, the installer
  detects it on loopback and skips the menu; the rack auto-claims, nothing to
  type. (If the hub isn't up yet, choose **2**.)
- **A different machine on the LAN** — choose **3** and enter the hub's address.
  Use its `.local` mDNS name (`http://bench.local:8000`), not a raw IP — a raw
  IP breaks when the DHCP lease changes. `guppi-rack` then prints a **claim
  code** you enter once in the dashboard.

You can skip the menu by setting the address up front:
`GUPPI_AGENT_URL=http://bench.local:8000 sudo -E bash …/install.sh`.

`guppi-rack` scans USB/VISA and the local Ethernet segment for instruments and
prints what it found. The rig appears in the dashboard within a few seconds of
`guppi-rack` starting. Your device layout lives in
**`/etc/guppi-rack/rig_config.yml`** (outside the source tree, so hub upgrades
don't touch it) — see [drivers.md](drivers.md) to add an instrument.

Like the hub, `guppi-rack` runs in the foreground (Ctrl-C to stop). To keep it
running after an SSH logout, start it inside `tmux` (`tmux new -s rack`) the
same way as the hub.

## 4. Use it

- **Dashboard** — live signals from every instrument the rack found.
- **Data viewer** — history over any time window; data is kept for a bounded
  window (7 days by default, `TELEMETRY_RETENTION_DAYS` in
  `/etc/guppi/hub.env`), while test executions and captured artifacts are kept.
- **Tests** — run sequenced test scripts against the bench; results and
  waveform captures attach to each execution.
- **Your data is yours** — the Postgres on the box is a normal Postgres; see
  [data-access.md](data-access.md).

## Upgrading

Re-run the installer. It upgrades in place; your data (under `/var/lib/guppi`
and in Postgres) is untouched.

## Pinning a version

Each release carries its own installer, pre-pinned:

```
curl -fsSL https://github.com/ezzatisawesome/guppi/releases/download/v0.1.0/install.sh | sudo bash
```
