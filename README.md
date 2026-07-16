# Guppi

**Your bench, on your network.** Guppi turns a Raspberry Pi (or any Debian box)
into a self-contained offline lab bench: live telemetry, instrument control, test
sequencing, and a web dashboard — no cloud, no account, no login.

## Install the hub

On the Pi:

```
curl -fsSL https://raw.githubusercontent.com/ezzatisawesome/guppi/main/install.sh | sudo bash
```

That's the whole install. It sets up PostgreSQL, PostgREST, NATS, and the Guppi
hub as systemd services, then serves the dashboard at `http://<pi>:8000` for
any browser on your LAN.

- **Pin a version** (installer and assets from the same release — reproducible):

  ```
  curl -fsSL https://github.com/ezzatisawesome/guppi/releases/download/v0.1.0/install.sh | sudo bash
  ```

  Each release carries its own `install.sh`, pre-pinned to that release. The
  one on `main` always installs the latest.
- **Upgrade**: re-run the installer.

## Connect your instruments

On the machine wired to the bench (the same Pi works fine):

```
sudo bash /opt/guppi/src/packages/rack/install.sh
guppi-rack
```

`guppi-rack` scans for USB/VISA and Ethernet instruments and pairs with the
hub — on the same box it auto-claims over loopback with nothing to type; on
another LAN machine it prints a claim code you enter once in the dashboard.

## Docs

- [Getting started](docs/getting-started.md) — blank SD card to live telemetry.
- [Troubleshooting](docs/troubleshooting.md) — services, logs, the common failures.
- [Direct data access](docs/data-access.md) — psql, PostgREST, pandas, Grafana; your database is yours.
- [Architecture](docs/architecture.md) — how the appliance works under the hood.

## What this repo is

The public distribution for Guppi: the installer, docs, and versioned
[releases](https://github.com/ezzatisawesome/guppi/releases) carrying
`guppi-src.tar.gz` (hub + rack source) and `guppi-ui-local.tar.gz` (the
prebuilt dashboard). Development happens in a separate repository — see
[CONTRIBUTING](CONTRIBUTING.md) for what helps (bug reports and instrument
requests do; pull requests here can't be merged).

## Support

- **Something broke** → [open a bug report](../../issues/new?template=bug-report.yml)
  with your release version and `journalctl -u guppi-hub` output.
- **An instrument you want supported** → [instrument request](../../issues/new?template=instrument-request.yml)
  with its `*IDN?` string.
- **Questions and ideas** → [Discussions](../../discussions).

## License

Guppi is proprietary software — free to install and run on your own bench, with
release source provided for transparency and security review. See
[LICENSE](LICENSE).

## Requirements

- Raspberry Pi 4/5 (or any arm64/amd64 Debian bookworm box), 2 GB+ RAM
- PostgreSQL ≥ 15 available from the distro (bookworm ships 15)
- A trusted LAN: the dashboard is open to anyone who can reach the Pi
  (read-only viewing by design; there are no accounts)
