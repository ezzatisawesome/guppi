# Instrument drivers

Guppi ships a large driver library — 200+ instruments across power supplies,
electronic loads, DMMs, oscilloscopes, spectrum / network / signal analyzers,
SMUs, function generators, lock-ins, magnet controllers, motion, photonics,
temperature, and vacuum. They live under
`packages/rack/src/devices/<category>/`; the one nearest your instrument is the
best template. When your instrument isn't covered — or you want the rack to read
a custom board — you write a driver: one Python class.

## How the rack finds drivers

Four sources, merged in this order (later wins on name collisions):

1. **Built-ins** — everything bundled with the rack.
2. **Entry points** — packages installed into the rack's environment that
   declare a `guppi.drivers` entry point. For drivers you distribute properly.
3. **`GUPPI_DRIVER_PATH`** — colon-separated `.py` files or directories.
   Good for trying a driver without touching config:
   `GUPPI_DRIVER_PATH=~/my-driver.py guppi rack`
4. **`drivers:` in `rig_config.yml`** — the usual place. On an installed rack
   this is **`~/.guppi/rig_config.yml`** (in your home, so hub upgrades never
   touch it). Each entry is a `.py` file or a driver package
   directory; relative paths resolve against the config file's directory:

   ```yaml
   drivers:
     - "/home/me/my-board-firmware/tools/driver"
   ```

At startup the rack logs `Loaded N driver(s) from config path: …` for each
source that contributed. A driver class is picked up if it subclasses the
rack's `Device` base and isn't abstract; classes whose name starts with `_`
are treated as private shared bases and skipped.

## Start from the right base

Most drivers subclass a **family base** that already implements the tedious
parts, not `Device` directly. Pick the closest fit:

| Base | For | Gives you |
| --- | --- | --- |
| `Device` | anything — a custom board, serial sensor, CAN DUT | the raw contract: you implement `signals()` + `measure()` |
| `ScpiInstrument` | a one-shot SCPI instrument (DMM, power meter) | a managed thread-safe `scpi` codec + connect/identify wiring |
| `ChannelInstrument` | N channels each reporting voltage & current — power supplies, electronic loads | per-channel `1.voltage` / `1.current` signals, channel select, and an `energizing` output capability |
| `ScpiScope` | oscilloscopes | the shared arm → trigger → fetch-waveform contract with artifact publishing |
| `SweptAnalyzer` | swept-frequency analyzers (spectrum / network / signal) | the arm → sweep → fetch-trace contract with swept-trace artifacts |

Subclass the family, fill in the SCPI specifics for your model, and the
capture/streaming plumbing comes for free — every base has a working example
next to yours under `packages/rack/src/devices/`.

**Scaffold one** with `make new-driver NAME=MyDevice` (add `KIND=psu` for a
channel-instrument skeleton; the default `KIND=sensor` is a bespoke `Device`).
It writes a ready-to-edit driver stub under `packages/rack/drivers/` (override
with `DIR=`) and prints the `rig_config.yml` snippet to wire it in. The sections
below show a driver from scratch on the raw `Device` base.

## A minimal driver

```python
from devices.core.codec import ScpiCodec
from devices.core.device import Device, DeviceSignal


class MyMeter(Device):
    """A one-signal SCPI instrument."""

    # The string used under `type:` in rig_config.yml. Defaults to the
    # class name if omitted.
    device_type = "MyMeter"

    # Substrings matched (case-insensitively) against the instrument's *IDN?
    # reply, so the rack's scan can auto-detect it. Leave empty to only
    # support explicit declaration in rig_config.yml.
    idn_models = ("MYMETER-2000",)

    # Short category for auto-labels of discovered units (meter1, meter2, …).
    category = "meter"

    def __init__(self, scpi: ScpiCodec):
        self.scpi = scpi

    def signals(self) -> list[DeviceSignal]:
        return [DeviceSignal(name="voltage", unit="V", label="Voltage")]

    def measure(self, name: str) -> float | None:
        if name == "voltage":
            return float(self.scpi.query("MEAS:VOLT?"))
        return None
```

Declare it in `rig_config.yml`:

```yaml
devices:
  - id: meter1
    name: "My Meter"
    type: MyMeter
    enabled: true
    connection:
      type: VISA
      address: "USB0::0x1234::0x5678::SERIAL::INSTR"
      timeout: 10.0
```

That's a working, streaming instrument: the telemetry sampler polls
`read_all()` (default: one `measure()` per declared signal) every tick and
the dashboard charts `meter1.voltage`.

## The pieces

**`signals()`** — declares what the device reports. Each `DeviceSignal` is a
device-local name (`"temperature"`, `"1.voltage"` for channel instruments), a
unit, and an optional label. The full path seen everywhere downstream is
`{device_id}.{name}`.

**`measure(name)` / `read_all()`** — how values are read. Override
`read_all()` when the instrument has a bulk query (one SCPI round-trip
instead of one per signal) — it's the per-tick hot path.

**`capabilities()` / `invoke(name, params)`** — writable controls (set a
voltage, toggle an output). Each `DeviceCapability` declares a name and a
JSON schema for its parameters. **If a capability can source power, set
`energizing=True`** — the safety watchdog de-energizes a rig by invoking
every energizing capability with `{"enabled": False}`, and it can only do
that for capabilities that are marked.

**Connected-state setup** — put initialization that needs a live connection
(channel discovery, forcing a safe state) in `__enter__`. The server enters
the driver after connecting; `__exit__` stays a no-op because the server owns
the connection lifecycle.

## Two connection shapes

**Rack-managed (SCPI instruments)** — the device has a `connection:` block in
config; the rack opens the transport (VISA/socket), wraps it in a
thread-safe SCPI codec, and passes it as your `__init__`'s first argument.
This is the `MyMeter` example above.

**Driver-owned (everything else)** — no `connection:` block; your driver
takes its own parameters (`port=`, `can_device=`, …) and opens whatever it
needs in `connect()`. Serial sensors, CAN boards, HTTP gadgets.

In both shapes, extra keys in the device's config block are matched by name
to your `__init__` parameters — declare `num_channels`, `bitrate`, or any
custom knob as a keyword argument and users can set it in YAML.

### Pinning USB serial ports (`port:`) — use `/dev/serial/by-id/`

A driver-owned device on USB (CDC-ACM/USB-serial) enumerates as
`/dev/ttyACM0`, `/dev/ttyUSB0`, and so on — **but that number is assigned by
plug/boot order, not by device.** Two USB instruments (say an ITECH supply and
a Pololu I2C adapter) can swap numbers across a reboot or a replug, so a
`port: /dev/ttyACM0` in config can silently point at the *wrong* instrument.
On the bench this showed up as one driver grabbing another's port (field test
§9): a NACK/timeout storm at best, two sessions corrupting one port at worst.

Pin `port:` to the **stable per-device symlink** under `/dev/serial/by-id/`
instead. That name is built from the device's vendor and serial number, so it
always follows the same physical unit:

```
$ ls -l /dev/serial/by-id/
usb-ITECH_Electronics_IT-M3904C-80-80_805255051817140031-if00 -> ../../ttyACM0
usb-Pololu_Corporation_Pololu_...-if00                          -> ../../ttyACM1
```

The `-> ../../ttyACMx` on the right is just today's number; pin the left-hand
name:

```yaml
- id: enables1
  type: PCA9539
  port: /dev/serial/by-id/usb-Pololu_Corporation_Pololu_...-if00
```

Cross-check which is which with `lsusb` (the ITECH is USB vendor `2ec7`); the
`by-id` name already embeds the maker. If `/dev/serial/by-id/` is missing, the
device reports no serial string — fall back to `/dev/serial/by-path/` (stable
per physical USB port; don't move the cable between ports).

The rack guards this: any `/dev/...` port a driver-owned device opens is
claimed before `connect()`, so two devices resolving to the *same* node fail
fast with an actionable "already in use" message instead of fighting over it.
The guard catches a *colliding* pin; `by-id` prevents the collision in the
first place. Auto-detect (leaving `port:` unset) can still grab a neighbour's
port — always pin USB serial ports.

## Self-describing devices (DUTs)

A board that reports its own signal catalog at runtime (e.g. over CAN) is
declared with `discover: true` and `role: dut`. Its signals come from a
manifest the driver publishes rather than from config, so it can hot-plug and
change shape between firmware versions. Set `sampling = Sampling.PUSH` when
the driver fills a cache from asynchronous messages instead of being polled.
See the `pb1` example in the stock `rig_config.yml`.

## Concurrency, briefly

Telemetry sampling, test phases, and dashboard commands can hit a driver from
different threads. The SCPI codec is thread-safe per call; for stateful
multi-step operations (select a channel, then act on it), wrap the steps in
`with self.scpi.transaction():` so they can't interleave.

## Distributing a driver as a package

For a driver you maintain and reuse across rigs, publish it as its own
pip-installable package instead of copying a `.py` file around. `guppi-rack`
exposes its SDK (`devices`, `catalog`, …), so your package depends on the rack
and advertises itself through the `guppi.drivers` entry point (source 2 above):

```toml
# pyproject.toml of your driver package
[project]
name = "guppi-driver-acme"
dependencies = ["guppi-rack"]

[project.entry-points."guppi.drivers"]
AcmePSU = "guppi_driver_acme:AcmePSU"   # name = the rig_config `type:`
```

`pip install guppi-driver-acme` into the rack's environment and it's discovered
automatically — no `drivers:` path or `GUPPI_DRIVER_PATH` needed.

## Checklist

- [ ] Subclasses `Device` (directly or via a family base like
      `ChannelInstrument`), name doesn't start with `_`
- [ ] `device_type` (or class name) matches `type:` in config
- [ ] `signals()` declares everything you report
- [ ] Bulk `read_all()` override if the instrument supports one query
- [ ] `energizing=True` on any capability that can source power
- [ ] Connected-state init (discovery, safe state) in `__enter__`
- [ ] Multi-step SCPI wrapped in `transaction()`
- [ ] Loads cleanly: `GUPPI_DRIVER_PATH=path/to/driver guppi rack` shows it
      in the startup scan

Instrument you'd rather not write a driver for?
[Open an instrument request](https://github.com/ezzatisawesome/guppi/issues/new?template=instrument-request.yml)
with its `*IDN?` string.
