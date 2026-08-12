# Guppi

Guppi turns a Raspberry Pi (or any Debian box) into a self-contained lab bench:
live telemetry, instrument control, automated test sequencing, and a web
dashboard. It runs entirely on your network — no cloud, no account, no login.

It speaks to your hardware through 200+ built-in instrument drivers (power
supplies, electronic loads, DMMs, oscilloscopes, SMUs, RF analyzers,
temperature controllers, and more), auto-detected on the bus — and runs test
scripts written against [OpenHTF](https://github.com/google/openhtf), with
measurements streaming live to the dashboard as they're taken.

## Quick start

```
curl -fsSL https://raw.githubusercontent.com/ezzatisawesome/guppi/main/install.sh | sudo bash
guppi hub          # the server side — leave it running

curl -fsSL https://raw.githubusercontent.com/ezzatisawesome/guppi/main/install.sh | sudo bash -s -- rack
guppi rack         # the instrument side — scans your bench and pairs

# then open http://<pi>:8000 from any browser on your LAN
```

Details below.

## Install the hub

The hub is the server side: database, message broker, dashboard, and test
orchestration. On the Pi:

```
curl -fsSL https://raw.githubusercontent.com/ezzatisawesome/guppi/main/install.sh | sudo bash
```

One command, ~2–4 minutes. The installer sets up PostgreSQL (a system
service), PostgREST, NATS, and the Guppi hub, then hands you one command:

```
guppi hub    # runs all servers in the foreground — logs in your terminal, Ctrl-C stops them
```

While it runs, the dashboard is at `http://<pi>:8000` for any browser on your
LAN. The Guppi servers are not daemons — closing the terminal stops them, and
after a reboot you run `guppi hub` again. To keep it running after you log out
of an SSH session, start it inside a terminal multiplexer you install yourself
(`sudo apt install tmux`, then `tmux new -s hub`) or under `nohup`.

- **Pin a version** (installer and assets come from the same release):

  ```
  curl -fsSL https://github.com/ezzatisawesome/guppi/releases/download/<tag>/install.sh | sudo bash
  ```

  Each [release](https://github.com/ezzatisawesome/guppi/releases) carries its
  own `install.sh`, pinned to that release. The one on `main` installs the
  latest.
- **Upgrade**: `guppi update` (or re-run the installer).

## Connect your instruments

The rack is the instrument side — it runs on the machine physically wired to
the bench (the same Pi is the common case). Same installer, `rack` component:

```
curl -fsSL https://raw.githubusercontent.com/ezzatisawesome/guppi/main/install.sh | sudo bash -s -- rack
guppi rack
```

The installer asks which hub this rack should pair with (this machine, a hub
elsewhere on your LAN, or Guppi Cloud). On startup `guppi rack` scans for
USB/VISA and Ethernet instruments and prints what it found, then pairs with
the hub. On the same box it claims automatically over loopback; on another LAN
machine it prints a claim code you enter once in the dashboard.

Devices, networked-instrument discovery, and safety abort limits are declared
in `rig_config.yml` — see [Configuring your rig](docs/rig-config.md). Validate
a config before booting with `guppi rack config check`.

## Run tests

Tests are plain Python files using OpenHTF, dropped into the rig's workspace.
Your configured instruments are injected as plugs (`PSU1`, `LOAD1`, …), and
helpers cover parameter sweeps, operator prompts, waveform capture, and
watchdog safety limits. Run them from the dashboard, or from any machine with
the `guppi` CLI:

```
guppi run <test> [--rig R]   # plan, approve, run; answer prompts inline
guppi results [-o DIR]       # export the latest run: run.json + measurements.csv + scope/
guppi abort                  # stop the running test
guppi rigs                   # list paired rigs
```

See [Writing tests](docs/openhtf-authoring-guide.md) to get started.

## Docs

- [Getting started](docs/getting-started.md) — blank SD card to live telemetry.
- [Configuring your rig](docs/rig-config.md) — the full `rig_config.yml` reference: devices, discovery, safety limits.
- [Writing tests](docs/openhtf-authoring-guide.md) — the OpenHTF test contract: phases, measurements, sweeps, prompts.
- [CLI reference](docs/cli.md) — every `guppi` command and option on one page.
- [Instrument drivers](docs/drivers.md) — how drivers load, and how to write one for your instrument or board.
- [Direct data access](docs/data-access.md) — psql, PostgREST, pandas, Grafana; your database is yours.
- [Troubleshooting](docs/troubleshooting.md) — services, logs, the common failures.
- [Architecture](docs/architecture.md) — how the single-box install works under the hood.

## What this repo is

The public distribution for Guppi: the installer, docs, and versioned
[releases](https://github.com/ezzatisawesome/guppi/releases) containing
`guppi-src.tar.gz` (hub + rack source) and `guppi-ui-local.tar.gz` (the
prebuilt dashboard). Development happens in a separate repository. See
[CONTRIBUTING](CONTRIBUTING.md) for what helps: bug reports and instrument
requests. Pull requests here can't be merged.

## Support

- **Something broke** → [open a bug report](../../issues/new?template=bug-report.yml)
  with your release version (`cat /etc/guppi/version`) and the last screen of
  `guppi hub` output.
- **An instrument you want supported** → [instrument request](../../issues/new?template=instrument-request.yml)
  with its `*IDN?` string.
- **Questions and ideas** → [Discussions](../../discussions).

## License

Guppi is proprietary software. It is free to install and run on your own bench;
release source is provided for transparency and security review. See
[LICENSE](LICENSE).

## Requirements

- Raspberry Pi 4/5 with the **64-bit** Raspberry Pi OS, or any arm64/amd64
  Debian bookworm/bullseye or Ubuntu 20.04+ box, 2 GB+ RAM
- PostgreSQL ≥ 15 (the installer adds the official pgdg repo automatically if
  your distro ships an older version)
- A trusted LAN: the dashboard is open to anyone who can reach the Pi
  (read-only viewing by design; there are no accounts)
