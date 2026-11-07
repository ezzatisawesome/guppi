# Guppi

Your lab bench in a browser. Guppi finds your instruments, streams live data to
a dashboard, and runs [OpenHTF](https://github.com/google/openhtf) tests. It
runs on your own network: no cloud, no account.

200+ instruments work out of the box: power supplies, loads, DMMs, scopes, SMUs,
analyzers, DAQs and more.

## Install

On the machine wired to your instruments (a Raspberry Pi, any Debian/Ubuntu box,
or Windows):

```
# Linux
curl -fsSL https://raw.githubusercontent.com/ezzatisawesome/guppi/main/install.sh | sudo bash

# Windows (PowerShell)
irm https://github.com/ezzatisawesome/guppi/releases/latest/download/install.ps1 | iex
```

Then start it and open the address it prints:

```
guppi up
```

Runs on 64-bit Raspberry Pi OS, Debian 11+ or Ubuntu 20.04+ (2 GB RAM), and
Windows 10 1803+. Anyone on your network can open the dashboard, so keep it on
a network you trust. On Windows, [Getting started](docs/getting-started.md#on-windows)
covers what differs: ports, the firewall prompt and uninstalling.

## Just the CLI

To drive a bench from your laptop:

```
# macOS or Linux
curl -fsSL https://raw.githubusercontent.com/ezzatisawesome/guppi/main/install.sh | bash -s -- cli

# Windows (PowerShell)
& ([scriptblock]::Create((irm https://github.com/ezzatisawesome/guppi/releases/latest/download/install.ps1))) -Cli
```

```
guppi use <bench>        # point it at your bench
guppi run <test>         # run a test
guppi runs --bundle      # export the latest run
guppi skills install     # teach Claude Code to drive Guppi
```

Upgrade anything with `guppi update`.

## Docs

- [Getting started](docs/getting-started.md)
- [How a test runs](docs/how-a-test-runs.md)
- [Writing tests](docs/openhtf-authoring-guide.md)
- [Dashboards](docs/dashboards.md)
- [Configuring your rig](docs/rig-config.md)
- [Instrument drivers](docs/drivers.md)
- [CLI reference](docs/cli.md)
- [Troubleshooting](docs/troubleshooting.md)
- [All docs](docs/README.md)

## Help

- Something broke: [bug report](../../issues/new?template=bug-report.yml) (include the release version and the last screen of `guppi up`)
- Want an instrument supported: [instrument request](../../issues/new?template=instrument-request.yml) (include its `*IDN?` reply)
- Questions: [Discussions](../../discussions)

This repo holds the installer, docs and [releases](https://github.com/ezzatisawesome/guppi/releases);
development happens elsewhere, so pull requests can't be merged
([CONTRIBUTING](CONTRIBUTING.md)). Guppi is free to run on your bench; see
[LICENSE](LICENSE).
