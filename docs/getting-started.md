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
PostgREST, NATS, and the Guppi hub, and gives you one command — `guppi hub` —
that runs all the Guppi servers in the foreground with their logs in your
terminal. Nothing runs as a hidden daemon.

```
guppi hub                 # NATS + PostgREST + hub, logs live in the terminal
# Ctrl-C                  # stops all three
```

> Everything Guppi lives under the one `guppi` command: `guppi hub` (this
> box's servers), `guppi rack …` (the instrument side, step 3), and
> `guppi run`/`results` (test execution, from any machine with the CLI). The
> hyphenated names `guppi-hub` and `guppi-rack` are the same programs and
> keep working.

`guppi hub` holds the terminal on purpose — you watch the live logs, and
Ctrl-C (or closing the terminal) stops everything. Nothing auto-starts,
including after a reboot: run `guppi hub` again.

If you're on the Pi over SSH and want the bench to survive logging out, start
it inside a terminal multiplexer you install yourself:

```
sudo apt install tmux     # once
tmux new -s hub           # open a session
guppi hub                 # start the bench inside it
# Ctrl-b, then d          # detach — leaves it running
tmux attach -t hub        # reattach later
```

While `guppi hub` runs, open **`http://<hostname>.local:8000`** from any
browser on the LAN. No account, no login — the dashboard is just there.

Sanity check:

```
curl http://localhost:8000/health
# → {"status":"ok","mode":"local","postgres":"ok"}
```

## 3. Connect your instruments

Same installer, `rack` component — run it on the machine physically wired to
the instruments (the same Pi is the common case, and there it reuses the
source already on disk instead of downloading again):

```
curl -fsSL https://raw.githubusercontent.com/ezzatisawesome/guppi/main/install.sh | sudo bash -s -- rack
guppi rack
```

The rack installer asks which hub this rack should pair with:

```
Which agent should this rack pair with?
    1) Guppi Cloud   — https://app.guppidev.com   (hosted; default)
    2) This machine  — http://127.0.0.1:8000       (a hub running on this box)
    3) Custom URL    — a self-host agent on your LAN (e.g. http://bench.local:8000)
```

- **Same box as the hub** — if `guppi hub` is already running, the installer
  detects it on loopback and skips the menu; the rack auto-claims, nothing to
  type. (If the hub isn't up yet, choose **2**.)
- **A different machine on the LAN** — choose **3** and enter the hub's address.
  Use its `.local` mDNS name (`http://bench.local:8000`), not a raw IP — a raw
  IP breaks when the DHCP lease changes. `guppi rack` then prints a **claim
  code** you enter once in the dashboard.

You can skip the menu by setting the address up front:
`curl -fsSL …/install.sh | sudo GUPPI_AGENT_URL=http://bench.local:8000 bash -s -- rack`.

`guppi rack` scans USB/VISA and the local Ethernet segment for instruments and
prints what it found. The rig appears in the dashboard within a few seconds of
`guppi rack` starting. Your device layout lives in
**`~/.guppi/rig_config.yml`** (in your home, so hub upgrades don't touch it and
you can edit it without sudo) — see [drivers.md](drivers.md) to add an instrument, or use
`guppi rack devices add` (guided wizard) and `guppi rack config check`.

Like the hub, `guppi rack` runs in the foreground (Ctrl-C to stop). To keep it
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

## 5. Run tests from your terminal (optional)

The dashboard can run tests on its own; the `guppi` CLI drives the same runs
from a terminal (`guppi run`, `guppi results`, `guppi abort`, `guppi rigs`),
talking to the hub over HTTP. **Hub and rack boxes already have it** — the
installers build the full CLI, so on the bench you just run it.

To drive runs from any other machine (a laptop on the bench LAN), install the
CLI from the release's source tarball and point it at the hub:

```
curl -fsSL -o /tmp/guppi-src.tar.gz \
  https://github.com/ezzatisawesome/guppi/releases/latest/download/guppi-src.tar.gz
tar -xzf /tmp/guppi-src.tar.gz -C /tmp
pipx install /tmp/guppi/packages/cli
export GUPPI_HUB=http://bench.local:8000    # or pass --hub per command
```

```
guppi rigs                # list paired rigs — a good first check
guppi run smoke-test      # derive the plan, approve, run; prompts answered inline
guppi results             # write the latest run bundle (run.json + CSVs + scope/)
```

It's the same program everywhere — one `guppi`, whether the installer built it
or you pipx-installed it.

## Upgrading

Stop the bench (Ctrl-C), then:

```
guppi update
```

It fetches the current installer and re-runs it for whatever this box has —
hub first, then rack. Your data (under `/var/lib/guppi` and in Postgres) is
untouched; a hub that fails to start rolls back to the previous version.
Re-running the installer by hand does exactly the same thing.

## Pinning a version

The command above always installs the latest release. To pin a specific one,
take its tag from the [releases page](https://github.com/ezzatisawesome/guppi/releases)
(releases are tagged `v0.1.0-rc.N`) and use that release's own pre-pinned
installer:

```
curl -fsSL https://github.com/ezzatisawesome/guppi/releases/download/v0.1.0-rc.10/install.sh | sudo bash
```
