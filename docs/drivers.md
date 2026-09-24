# Instrument drivers

Guppi ships a large driver library — 200+ instruments across power supplies,
electronic loads, DMMs, oscilloscopes, spectrum / network / signal analyzers,
SMUs, function generators, lock-ins, magnet controllers, motion, photonics,
temperature, and vacuum. When your instrument isn't covered — or you want the
rack to read a custom board — you write a driver: one Python class.

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

Drivers load at rack startup — after adding a `drivers:` entry or editing
driver code, **restart `guppi rack`** to pick it up (there is no hot reload).
The startup log prints a `Loaded N driver(s) from …` line for each source
that contributed. A driver class is picked up if it subclasses the rack's
`Device` base and isn't abstract; classes whose name starts with `_` are
treated as private shared bases and skipped.

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
capture/streaming plumbing comes for free. Everything you import lives in
two modules: `devices.core.device` (`Device`, `ScpiInstrument`,
`ChannelInstrument`, `DeviceSignal`, `DeviceCapability`, `EnumOption`,
`Read`, `Sampling`) and `devices.core.codec` (`ScpiCodec`).

### What a `ChannelInstrument` subclass implements

The base generates the per-channel signals and capabilities; you supply the
per-channel SCPI:

- `measure_voltage(channel)` / `measure_current(channel)` — measured values
- `set_voltage(channel, voltage)` / `set_current(channel, current)` — setpoints
- `get_output(channel)` / `set_output(channel, enabled)` — output state

The base's `__init__(scpi, num_channels=None, channel_limits=None, ...)`
takes the rack-managed codec first, like `ScpiInstrument`; a fixed-channel
model can just pin `num_channels = 2` as a class attribute instead. A
minimal single-channel electronic load:

```python
from devices.core.device import ChannelInstrument


class AcmeEL300(ChannelInstrument):
    device_type = "AcmeEL300"
    idn_models = ("EL-300",)
    num_channels = 1

    def measure_voltage(self, channel):
        return float(self.scpi.query("MEAS:VOLT?"))

    def measure_current(self, channel):
        return float(self.scpi.query("MEAS:CURR?"))

    def set_voltage(self, channel, voltage):
        self._validate_voltage(channel, voltage)
        self.scpi.write(f"VOLT {voltage}")      # CV-mode level

    def set_current(self, channel, current):
        self._validate_current(channel, current)
        self.scpi.write(f"CURR {current}")

    def get_output(self, channel):
        return self.scpi.query("INP?").strip() in ("1", "ON")

    def set_output(self, channel, enabled):
        self.scpi.write(f"INP {'ON' if enabled else 'OFF'}")
```

That's a full device surface — `1.voltage` / `1.current` telemetry, setpoint
readbacks, and a watchdog-killable output toggle — from six methods. (The
base generates capabilities for all six, so implement all of them — the
`_validate_*` helpers enforce the per-channel `channel_limits` from config.)

If your instrument has a *stateful* channel select (select once, then read),
override `measure_channel(channel)` to select and read voltage, current, and
output state inside one transaction — that's the per-tick hot path, and it
turns three round-trips into one.

Users can narrow any channel instrument from config with no driver code —
the loader applies both keys after construction (`select_channels()`), so
your `__init__` doesn't need to accept them:

```yaml
- id: psu1
  type: BK9141
  channels: [1, 2]      # expose only these channels (signals + controls)
  poll_channels: 1      # stream telemetry for just a subset of those
```

`channels` takes an int or a list; `poll_channels` must be a subset of the
exposed channels (writes still work on everything exposed).

**Scaffold one** with `make new-driver NAME=MyDevice` — from a source
checkout of the repo (add `KIND=psu` for a
channel-instrument skeleton; the default `KIND=sensor` is a bespoke `Device`).
It writes a ready-to-edit driver stub (choose where with `DIR=`) and prints
the `rig_config.yml` snippet to wire it in. The sections
below show a driver from scratch on the raw `Device` base.

## Multi-file drivers are package directories

A driver that spans several files must ship as a **package directory** — an
`__init__.py` exposing the driver class, siblings imported relatively — and
the `drivers:` entry points at the directory:

```
my-board-driver/
  __init__.py        # from .protocol import …; class MyBoard(Device): …
  protocol.py
  frames.py
```

Relative imports only work in the package form because of how the loader
imports each shape: for a package directory it puts the *parent* directory
on `sys.path` and imports the package by name, so `from .protocol import …`
resolves; a bare `.py` is loaded as an isolated module with no `sys.path`
change, so it cannot import a sibling file at all. A shared transport module
(one adapter used by several chip drivers) therefore belongs inside the
package, imported relatively. And don't wrap imports of real dependencies in
`try/except` — a missing dependency should fail loudly at load, not surface
later as a half-working device.

If your driver needs a third-party library (`pyserial`, a vendor SDK), install
it **into the rack's environment** — the driver runs inside the rack process,
so a library installed anywhere else won't be found. For a properly
distributed driver, declare it as a dependency of your package instead (see
[Distributing a driver as a package](#distributing-a-driver-as-a-package)).
A driver can also declare
`requires = (("uldaq", "daq"),)` — (module, extra) pairs — so a missing
optional SDK is named up front at load rather than failing mid-import.

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

That's a working, streaming instrument. Restart `guppi rack` and success
looks like this: the startup scan lists the device, `meter1.voltage` appears
in the signal catalog, and the dashboard can chart it. Under the hood the
telemetry sampler polls `read_all()` (default: one `measure()` per declared
signal) every tick.

## The pieces

**`signals()`** — declares what the device reports. Each `DeviceSignal` is a
device-local name (`"temperature"`, `"1.voltage"` for channel instruments), a
unit, and an optional label. The full path seen everywhere downstream is
`{device_id}.{name}`. Optional metadata makes the UI smarter: `signal_type`,
`direction`, `min`/`max` bounds, and for non-numeric signals `field_kind`
(`"bool"` / `"enum"`) with `options` — a tuple of
`EnumOption(token, code, label)` mapping the instrument's string tokens to
the numeric codes that stream as telemetry.

`signal_type` is a free-form hint that the catalog projects to two UI types:
`"digital"`, `"output"`, `"bool"`, `"boolean"`, or `"state"` become
**digital** (renderable as a toggle); anything else (`"voltage"`,
`"current"`, `"temperature"`, …) is **analog** (readouts, bars, gauges,
setpoints). `direction` gates controls: `"in"` (measured — the default) is
always read-only, even if a matching write capability exists; use `"out"`
(commanded) or `"bidir"` (measured *and* commandable) for anything a user
should be able to set from the dashboard.

Each signal also has a **read discipline** (`read=`): `Read.POLLED` (default
— sampled every tick), `Read.SETTER_OWNED` (served from the write cache —
programmed setpoints, no instrument query per tick), or `Read.ON_DEMAND`
(never streamed — large vector tables fetched only when asked).
`SETTER_OWNED` is what `ChannelInstrument` uses for its `*_setpoint`
readbacks; on a raw `Device`, the equivalent is simply caching the last
written value in `invoke()` and returning it from `measure()` — no
instrument query per tick.

**`measure(name)` / `read_all()`** — how values are read. Override
`read_all()` when the instrument has a bulk query (one SCPI round-trip
instead of one per signal) — it's the per-tick hot path. Two specialized
variants: `read_all_timed()` returns each value stamped with its own
acquisition moment (for high-rate drivers that read sequentially), and
`drain()` is for buffered, self-clocking sources (CAN, DAQs) that accumulate
samples on their own thread and hand them over in batches.

**Read failures and quarantine** — how you fail matters. **Raising** from
`measure()`/`read_all()` counts as a failed read: after 5 consecutive
failures the device is quarantined — marked degraded, polled only every
30 s (with a `reconnect()` attempt before each retry) — and it recovers
automatically on the first successful read. **Returning `{}` or a partial
dict is a healthy tick**: missing signals just aren't recorded, the failure
counter resets, and polling continues at full cadence. So when the hardware
is genuinely unreachable, *raise* — returning `{}` silently hides a
disconnected device forever. Return a partial dict only when the device is
healthy but some signals legitimately have no value this tick (e.g. a DUT
that is intentionally unpowered).

**`capabilities()` / `invoke(name, params)`** — writable controls (set a
voltage, toggle an output). Each `DeviceCapability` declares a name and a
JSON schema for its parameters — a map of parameter name → schema fragment,
as in the examples below. **If a capability can source *or sink* power (a
supply output, a load input, a relay feeding a DUT), set `energizing=True`**
— the safety watchdog de-energizes a rig by invoking every energizing
capability with `{"enabled": False}`, and it can only do that for
capabilities that are marked. That contract means an energizing capability
must accept a boolean parameter named exactly `enabled`.

### Pairing a capability with a signal (dashboard controls)

The dashboard renders an editable control for a signal only when a
capability with the **matching name** exists — otherwise the signal is
read-only. Pairing is by naming convention on the last path segment:

| Signal | Paired capability | Control | Params sent |
| --- | --- | --- | --- |
| digital `X` (direction `out`/`bidir`) | `set_X` | toggle | `{"enabled": bool}` |
| analog `foo_setpoint` (`out`/`bidir`) | `set_foo` | numeric setpoint | `{"value": number}` |
| enum field `mode` (`field_kind="enum"`) | `set_mode` | dropdown | `{"value": "<token>"}` |

Dotted names normally pair on the leaf: `1.output` ↔ `1.set_output`,
`P1_0.value` ↔ `P1_0.set_value`. A channel-less board's digital net may
instead put `set_` right after the device id
(`pb1.BATT1.EN` ↔ `pb1.set_BATT1.EN`) — the dashboard generates both
candidates and uses whichever your driver actually declares. So to make a
value editable you need all
three pieces: a signal with `direction="out"` or `"bidir"`, a capability
named `set_{leaf}` (with the `_setpoint` suffix stripped for setpoints), and
the right parameter key in your `invoke()` — `enabled` for toggles, `value`
for everything else. A toggle additionally requires the signal to project as
digital (see `signal_type` above). `ChannelInstrument` follows all of these
conventions for you.

**`validate_config(cfg)`** — an optional `@classmethod` that rejects
obviously-bad config values (a negative `num_channels`, an out-of-range
frequency) with a clear error at `guppi rack config check` time and again at
load, instead of a confusing failure at runtime.

**Connected-state setup** — put initialization that needs a live connection
(channel discovery, forcing a safe state) in `__enter__`. The server enters
the driver after connecting; `__exit__` stays a no-op because the server owns
the connection lifecycle.

## Two connection shapes

**Rack-managed (SCPI instruments)** — the device has a `connection:` block in
config; the rack opens the transport (VISA/socket), wraps it in a
thread-safe SCPI codec, and passes it as your `__init__`'s first argument.
This is the `MyMeter` example above. `connection.type` defaults to `visa`;
a raw TCP instrument uses a VISA socket address
(`TCPIP0::192.168.1.50::5025::SOCKET`), and any extra keys in the
`connection:` block (e.g. `read_termination: "\n"`) are forwarded to the
transport.

**Driver-owned (everything else)** — no `connection:` block; your driver
takes its own parameters (`port=`, `can_device=`, …) and opens whatever it
needs in `connect()`. Serial sensors, CAN boards, HTTP gadgets.

In both shapes, extra keys in the device's config block are matched by name
to your `__init__` parameters — declare `num_channels`, `bitrate`, or any
custom knob as a keyword argument and users can set it in YAML. Values
arrive **verbatim with their YAML types** (no coercion): `address: 0x74`
arrives as an int, `address: "0x74"` as a string — normalise in `__init__`
(`int(x, 0)` handles both). Keys that match no parameter are silently
ignored, so a typo'd knob won't error — double-check spelling against your
signature.

### Pinning USB serial ports (`port:`) — use `/dev/serial/by-id/`

A driver-owned device on USB (CDC-ACM/USB-serial) enumerates as
`/dev/ttyACM0`, `/dev/ttyUSB0`, and so on — **but that number is assigned by
plug/boot order, not by device.** Two USB instruments (say an ITECH supply and
a Pololu I2C adapter) can swap numbers across a reboot or a replug, so a
`port: /dev/ttyACM0` in config can silently point at the *wrong* instrument.
On a real bench this shows up as one driver grabbing another's port: a
NACK/timeout storm at best, two sessions corrupting one port at worst.

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

## A driver-owned example — controlling an eval board

The other shape in full: a buck-converter eval board that talks a simple
ASCII protocol over USB serial. The driver owns the connection, reports
measured signals, and exposes two dashboard-controllable pairs — a setpoint
and an enable:

```python
import serial

from devices.core.device import Device, DeviceCapability, DeviceSignal


class BuckEval(Device):
    """Eval board speaking `VOUT?` / `SET <mv>` / `EN 0|1` at 115200."""

    category = "dut"

    def __init__(self, port: str, baud: int = 115200):
        self.port, self.baud = port, baud
        self.ser: serial.Serial | None = None
        self._vset: float | None = None

    def connect(self) -> None:
        self.ser = serial.Serial(self.port, self.baud, timeout=1.0)

    def disconnect(self) -> None:
        if self.ser:
            self.ser.close()

    def __enter__(self):
        self._cmd("EN 0")            # force a safe state before anything runs
        return self

    def _cmd(self, line: str) -> str:
        self.ser.write(f"{line}\n".encode())
        return self.ser.readline().decode().strip()

    def signals(self) -> list[DeviceSignal]:
        return [
            DeviceSignal(name="vout", unit="V", label="Output voltage"),
            DeviceSignal(name="fault", unit="", label="Fault flag"),
            # The controllable pair (see "Pairing a capability with a signal"):
            # vout_setpoint + set_vout -> numeric field; enable (digital,
            # bidir) + set_enable -> toggle.
            DeviceSignal(name="vout_setpoint", unit="V", direction="out",
                         label="Vout setpoint"),
            DeviceSignal(name="enable", signal_type="output",
                         direction="bidir", label="Enable"),
        ]

    def measure(self, name: str) -> float | None:
        if name == "vout":
            return float(self._cmd("VOUT?")) / 1000.0
        if name == "fault":
            return float(self._cmd("FAULT?"))
        if name == "vout_setpoint":
            return self._vset            # cached last write; no query per tick
        if name == "enable":
            return float(self._cmd("EN?"))
        return None

    def capabilities(self) -> list[DeviceCapability]:
        return [
            DeviceCapability(
                name="set_vout",
                param_schema={"value": {"type": "number", "minimum": 0.8, "maximum": 5.5}},
                label="Set Vout",
            ),
            DeviceCapability(
                name="set_enable",
                param_schema={"enabled": {"type": "boolean"}},
                label="Output enable",
                energizing=True,     # the watchdog can now de-energize this board
            ),
        ]

    def invoke(self, name: str, params: dict) -> None:
        if name == "set_vout":
            self._cmd(f"SET {int(params['value'] * 1000)}")
            self._vset = params["value"]
        elif name == "set_enable":
            self._cmd(f"EN {1 if params['enabled'] else 0}")
        else:
            raise ValueError(f"unknown capability {name!r}")
```

Wire it up — no `connection:` block; the `port` and `baud` keys land on
`__init__` by name (pin the port — [see above](#pinning-usb-serial-ports-port--use-devserialby-id)):

```yaml
devices:
  - id: buck1
    name: "Buck eval board"
    type: BuckEval
    enabled: true
    port: /dev/serial/by-id/usb-Acme_BuckEval_1234-if00
```

Restart `guppi rack` and you have `buck1.vout` charting live, a
`buck1.vout_setpoint` numeric field and `buck1.enable` toggle ready to drop
on a dashboard (each pairs with its `set_` capability by name), and — because the enable is marked `energizing` — a board the
safety watchdog shuts off on any abort. Sequence buttons and OpenHTF tests
drive the same two capabilities.

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

Beyond `query()` / `write()`, the codec gives you: `query_bytes()` /
`read_bytes()` for binary block data (waveforms, screenshots), `clear()` to
resynchronize after a framing glitch, and
`with self.scpi.control_timeout(2.0):` to wrap per-tick reads in a short
timeout — a hung instrument then fails in ~2 s instead of blocking the tick
for the full transport timeout (10 s default).

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

## Verifying a driver

The fastest loop while developing: point `GUPPI_DRIVER_PATH` at your file and
start the rack —

```
GUPPI_DRIVER_PATH=path/to/driver guppi rack
```

Success looks like: the startup scan's `Loaded N driver(s)` line includes
your source, the device appears in the scan with its signals, and each
`{device_id}.{signal}` shows live values in the signal catalog and charts.
If the class isn't picked up, check that it subclasses `Device` (directly or
via a family base), isn't abstract, and doesn't start with `_`; if the device
doesn't construct, check that `type:` in config matches `device_type` (or the
class name). Before calling it done, confirm any power-sourcing capability is
marked `energizing=True` — abort the rig from the dashboard and watch the
output actually turn off.

Instrument you'd rather not write a driver for?
[Open an instrument request](https://github.com/ezzatisawesome/guppi/issues/new?template=instrument-request.yml)
with its `*IDN?` string.
