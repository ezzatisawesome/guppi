# Getting started

From blank machine to live telemetry on your bench.

## 1. Prepare the bench computer

Any 64-bit Debian-family Linux box works: **Debian** (bookworm or bullseye),
**Ubuntu 20.04+**, or **Raspberry Pi OS Lite 64-bit**, on arm64 or amd64,
running systemd. A Raspberry Pi 4/5 is the common choice, but a mini PC, an
old laptop, or a VM on the bench network all work the same.

- On a Pi: flash **Raspberry Pi OS Lite 64-bit** (Raspberry Pi Imager is
  fine) — make sure it's the 64-bit image; 32-bit installs are rejected.
- Get it on your LAN (Ethernet recommended for the bench) and SSH in.
- Give it a memorable hostname (`sudo hostnamectl set-hostname bench`). You'll
  browse to `http://bench.local:8000` — the mDNS name survives DHCP lease
  changes; a raw IP doesn't.
- That `.local` name needs mDNS on the bench box. **Raspberry Pi OS has it
  already**; a plain Debian or Ubuntu Server image does not, and the Guppi
  installer doesn't add it — so on those, either `sudo apt install avahi-daemon`
  or use the IP the installer prints and accept that it moves with the DHCP
  lease. The installer tells you which case you're in.

## 2. Install Guppi

```
curl -fsSL https://raw.githubusercontent.com/ezzatisawesome/guppi/main/install.sh | sudo bash
```

One command, ~2–4 minutes on a Pi. It installs PostgreSQL (a system service),
PostgREST, NATS, the Guppi **hub** (the server side) and the Guppi **rack**
(the instrument side), and points the rack at the hub on this box — so there is
no pairing question to answer and no claim code to type.

Only want the hub on this machine — because the instruments are wired to a
different one? Add `--no-rack`, and see
[A bench split across two machines](#a-bench-split-across-two-machines).

## 3. Run the bench

```
guppi up
```

That is the whole thing: the hub and the rack, together. It starts the hub
first and waits for it to answer before the rack goes looking for it, gives
each one its own pane so you can read their logs apart, prints the dashboard
address, and stops both on a single Ctrl-C.

```
  dashboard  http://bench.local:8000
 ┌──────────────────────────────────────────────────────────┐
 │ hub ─────────────────────────────────────────────────────│
 │ INFO  uvicorn running on http://0.0.0.0:8000             │
 │ INFO  GET /api/telemetry/frames 200 (3ms)                │
 │ rack ────────────────────────────────────────────────────│
 │   ok   psu1    Keysight RP5900   (VISA TCPIP)            │
 │   ok   dmm1    Siglent SDM3045X  (LAN)                   │
 │ dashboard http://bench.local:8000  ·  Ctrl-C stops both  │
 └──────────────────────────────────────────────────────────┘
```

Stopping both together matters: a Ctrl-C that leaves only the rack running
leaves it holding your instruments open, and the next start then fails on a
locked device. On exit the tail of both logs is left in your terminal, so a
crash is still there to read.

> Piping or redirecting the output turns the split off and goes back to one
> labelled stream (`hub │ …`, `rack │ …`); `guppi up --no-split` does the same
> on a terminal. `guppi hub` and `guppi rack` still run either half alone.

Nothing runs as a hidden daemon and nothing auto-starts, including after a
reboot: run `guppi up` again. To keep it running after you log out of SSH,
start it inside a terminal multiplexer (install one first):

```
sudo apt install tmux     # once
tmux new -s bench         # open a session
guppi up                  # start the bench inside it
# Ctrl-b, then d          # detach — leaves it running
tmux attach -t bench      # reattach later
```

Open the address it printed from any browser on the LAN. No account, no login —
the dashboard is just there.

Sanity check:

```
curl http://localhost:8000/health
# → {"status":"ok","mode":"local","postgres":"ok"}
```

> Everything Guppi lives under the one `guppi` command: `guppi up` (the whole
> bench), `guppi hub` / `guppi rack …` (either half), and `guppi run` /
> `guppi runs` (test execution, from any machine with the CLI). The hyphenated
> names `guppi-hub` and `guppi-rack` are the same programs and keep working.

## 4. Connect your instruments

The rack is already installed and already running under `guppi up` — it scans
USB/VISA and the local Ethernet segment at startup and prints what it found,
in its own pane:

```
  guppi rack  · 7f3a21
  ok   psu1      Keysight RP5900   (VISA TCPIP)
  ok   dmm1      Siglent SDM3045X  (LAN)
  fail eload1    BK 8600           not responding — check power and cabling
  2 ready · 1 unreachable
```

The rig appears in the dashboard within a few seconds. Your device layout lives
in **`~/.guppi/rig_config.yml`** (in your home, so upgrades don't touch it and
you can edit it without sudo) — but you shouldn't have to open it by hand.
Open the rig in Guppi and choose **Instruments**: it scans the bench, adds what
it finds, edits anything in place, and tests an instrument before saving. See
[drivers.md](drivers.md) to write a driver for something it doesn't know, and
`guppi rack config check` to validate the file.

### A bench split across two machines

Sometimes the instruments are wired to a different box than the one you want
running the server — a lab PC with the GPIB card, say, and a Pi for the hub.
Install the hub with `--no-rack`, then install the rack by itself on the
instrument machine:

```
curl -fsSL …/install.sh | sudo bash -s -- --no-rack      # on the hub box
curl -fsSL …/install.sh | sudo bash -s -- rack           # on the instrument box
```

The rack installer asks which hub to pair with:

```
Which agent should this rack pair with?
    1) Guppi Cloud   — https://guppi-agent.fly.dev   (hosted)
    2) This machine  — http://127.0.0.1:8000       (the hub installed on this box; default)
    3) Custom URL    — a self-host agent on your LAN (e.g. http://bench.local:8000)
```

Choose **3** and give the hub's address. Use its `.local` mDNS name
(`http://bench.local:8000`), not a raw IP — a raw IP breaks when the DHCP lease
changes. You can skip the question entirely by setting the address up front:
`curl -fsSL …/install.sh | sudo GUPPI_AGENT_URL=http://bench.local:8000 bash -s -- rack`.

A rack on a different box from its hub is **not** auto-claimed — that shortcut
is only safe for a rack on the hub's own machine — so `guppi rack` prints a
pairing link and a claim code and waits. Claim it whichever way suits:

```
guppi claim A1B2 C3D4 E5F6      # on the hub box, no browser needed
```

…or open the printed link in the hub's dashboard, or click the rack pill in the
header and type the code into the field there.

Then run `guppi rack` on the instrument box and `guppi hub` on the hub box —
`guppi up` is for a bench where both live together.

### Drivers that need extra dependencies

Most instruments (USB/VISA, serial, networked) work out of the box. A few driver
families need an optional Python extra, and one needs a C library too:

| Hardware | Extra | Also needs |
|----------|-------|------------|
| USB-CAN adapters (CAN DUTs) | `can` | — (installed by default) |
| MCC / Digilent USB DAQ (USB-1608G…) | `daq` | MCC **libuldaq** (prebuilt wheel; OS `libusb-1.0-0`) |

The install handles this automatically: if the hardware is plugged in at
install time, it detects the USB vendor, installs the matching extra into the
**rack's own venv**, and for MCC DAQs drops in the prebuilt `guppi-libuldaq`
wheel (Linux x86_64 / aarch64, macOS arm64 — no compiler, seconds). Only when no
wheel fits the platform does it fall back to building `libuldaq` from source. To
opt in for hardware you'll plug in later, name the extras up front — the
variable reaches the rack part of a combined install too:

```
curl -fsSL …/install.sh | sudo GUPPI_RACK_EXTRAS=daq bash              # hub + rack
curl -fsSL …/install.sh | sudo GUPPI_RACK_EXTRAS=daq bash -s -- rack   # rack only
```

Already running and hit `missing driver dependency … run 'guppi rack deps
install <extra>'`? That command installs the extra into the rack's venv (not the
CLI or hub venv — the three-venv trap it exists to avoid), and for `daq` fetches
the prebuilt library wheel in the same step:

```
guppi rack deps install daq     # uldaq bindings + the prebuilt libuldaq wheel
guppi rack deps list            # see the available extras
```

`guppi rack config check` also preflights every enabled device's dependencies,
so a missing extra is caught before boot with the exact fix — not as a runtime
error at connect.

The wheel needs the OS `libusb-1.0` runtime (`libusb-1.0-0` on Debian /
Raspberry Pi OS — present on every standard image; the installer checks). If
there is no wheel for your platform (32-bit Raspberry Pi OS, for instance),
build `libuldaq` by hand and the driver uses the system copy:

```
sudo apt-get install -y gcc g++ make bzip2 libusb-1.0-0-dev
cd /tmp
curl -fsSL https://github.com/mccdaq/uldaq/releases/download/v1.2.1/libuldaq-1.2.1.tar.bz2 | tar -xj
cd libuldaq-1.2.1 && ./configure && make -j"$(nproc)" && sudo make install && sudo ldconfig
```

## 5. Use it

- **Dashboard** — live signals from every instrument the rack found.
- **Data viewer** — history over any time window; telemetry is kept
  indefinitely (prune channels you don't need from the Storage tab to reclaim
  space), and test executions and captured artifacts are kept.
- **Tests** — run sequenced test scripts against the bench; results and
  waveform captures attach to each execution.
- **Your data is yours** — the Postgres on the box is a normal Postgres; see
  [data-access.md](data-access.md).

## 6. Run tests from your terminal (optional)

The dashboard can run tests on its own; the `guppi` CLI drives the same runs
from a terminal (`guppi run`, `guppi runs`, `guppi abort`, `guppi rigs`),
talking to the hub over HTTP. **Hub and rack boxes already have it** — the
installers build the full CLI, so on the bench you just run it.

To drive the bench from any other machine (a laptop on the bench LAN), install
the CLI from the release's source tarball and point it at the hub. The CLI
needs Python 3.12; `uv` fetches it for you:

```
curl -fsSL -o /tmp/guppi-src.tar.gz \
  https://github.com/ezzatisawesome/guppi/releases/latest/download/guppi-src.tar.gz
tar -xzf /tmp/guppi-src.tar.gz -C /tmp
uv tool install --python 3.12 /tmp/guppi/packages/cli   # or: pipx install --python python3.12 …
guppi use condor               # the bench's hostname (or IP); checked, then saved for every command
guppi skills install           # optional: teach Claude Code to build dashboards
```

From then on, dashboards and data views you (or Claude Code) write on the
laptop go to the bench with `guppi push` and show up in its browser tabs
within seconds. See [Dashboards and data views as files](cli.md#dashboards-and-data-views-as-files).

```
guppi rigs                # list paired rigs — a good first check
guppi run smoke-test      # derive the plan, approve, run; prompts answered inline
guppi runs --bundle       # write the latest run bundle (run.json + CSVs + scope/)
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
curl -fsSL https://github.com/ezzatisawesome/guppi/releases/download/v0.1.0-rc.43/install.sh | sudo bash
```
