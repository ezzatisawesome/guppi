# Guppi

Guppi turns a Raspberry Pi (or any Debian box) into a self-contained lab bench:
live telemetry, instrument control, test sequencing, and a web dashboard. It runs
entirely on your network — no cloud, no account, no login.

## Install the hub

On the Pi:

```
curl -fsSL https://raw.githubusercontent.com/ezzatisawesome/guppi/main/install.sh | sudo bash
```

The installer sets up PostgreSQL, PostgREST, NATS, and the Guppi hub as systemd
services, then serves the dashboard at `http://<pi>:8000` for any browser on
your LAN.

- **Pin a version** (installer and assets come from the same release):

  ```
  curl -fsSL https://github.com/ezzatisawesome/guppi/releases/download/v0.1.0/install.sh | sudo bash
  ```

  Each release carries its own `install.sh`, pinned to that release. The one on
  `main` installs the latest.
- **Upgrade**: re-run the installer.

## Connect your instruments

On the machine wired to the bench (the same Pi works fine):

```
sudo bash /opt/guppi/src/packages/rack/install.sh
guppi-rack
```

`guppi-rack` scans for USB/VISA and Ethernet instruments and pairs with the
hub. On the same box it claims automatically over loopback. On another LAN
machine it prints a claim code you enter once in the dashboard.

## Docs

- [Getting started](docs/getting-started.md) — blank SD card to live telemetry.
- [Troubleshooting](docs/troubleshooting.md) — services, logs, the common failures.
- [Direct data access](docs/data-access.md) — psql, PostgREST, pandas, Grafana; your database is yours.
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
  with your release version and `journalctl -u guppi-hub` output.
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
