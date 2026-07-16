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

Start the bench in tmux so it keeps running after you close the terminal:

```
tmux new -s hub           # open a session
guppi-hub                 # NATS + PostgREST + hub, logs live in the terminal
# Ctrl-b, then d          # detach — servers keep running

tmux attach -t hub        # come back to the logs
tmux ls                   # see what's running
```

While `guppi-hub` runs, open **`http://<hostname>.local:8000`** from any
browser on the LAN. No account, no login — the dashboard is just there.

After a reboot, run `guppi-hub` again — nothing auto-starts.

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

`guppi-rack` scans USB/VISA and the local Ethernet segment for instruments,
prints what it found, and pairs with the hub:

- **Same box as the hub** — it auto-claims over loopback. Nothing to type.
- **A different machine on the LAN** — set the hub's address first
  (`GUPPI_AGENT_URL=http://bench.local:8000 sudo -E bash …/install.sh`);
  `guppi-rack` then prints a **claim code** you enter once in the dashboard.

The rig appears in the dashboard within a few seconds of `guppi-rack` starting.

`guppi-rack` runs in the foreground on purpose — you see the instrument scan
and the live output. To keep it running after you close the terminal, use tmux
(the rack installer sets it up):

```
tmux new -s rack          # open a session
guppi-rack                # start the rack inside it
# Ctrl-b, then d          # detach — the rack keeps running

tmux attach -t rack       # come back to the live output
tmux ls                   # see what's running
```

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
