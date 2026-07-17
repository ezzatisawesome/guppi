# Instrument drivers

Guppi ships drivers for common bench instruments (B&K Precision supplies,
Chroma loads, Siglent scopes, …). When your instrument isn't covered — or you
want the rack to read a custom board — you write a driver: one Python class.

## How the rack finds drivers

Four sources, merged in this order (later wins on name collisions):

1. **Built-ins** — everything bundled with the rack.
2. **Entry points** — packages installed into the rack's environment that
   declare a `guppi.drivers` entry point. For drivers you distribute properly.
3. **`GUPPI_DRIVER_PATH`** — colon-separated `.py` files or directories.
   Good for trying a driver without touching config:
   `GUPPI_DRIVER_PATH=~/my-driver.py guppi-rack`
4. **`drivers:` in `rig_config.yml`** — the usual place. On an installed rack
   this is **`/etc/guppi-rack/rig_config.yml`** (kept outside the source tree so
   hub upgrades never touch it). Each entry is a `.py` file or a driver package
   directory; relative paths resolve against the config file's directory:

   ```yaml
   drivers:
     - "/home/me/my-board-firmware/tools/driver"
   ```

At startup the rack logs `Loaded N driver(s) from config path: …` for each
source that contributed. A driver class is picked up if it subclasses the
rack's `Device` base and isn't abstract; classes whose name starts with `_`
are treated as private shared bases and skipped.

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

## Checklist

- [ ] Subclasses `Device` (directly or via a family base like
      `ChannelInstrument`), name doesn't start with `_`
- [ ] `device_type` (or class name) matches `type:` in config
- [ ] `signals()` declares everything you report
- [ ] Bulk `read_all()` override if the instrument supports one query
- [ ] `energizing=True` on any capability that can source power
- [ ] Connected-state init (discovery, safe state) in `__enter__`
- [ ] Multi-step SCPI wrapped in `transaction()`
- [ ] Loads cleanly: `GUPPI_DRIVER_PATH=path/to/driver guppi-rack` shows it
      in the startup scan

Instrument you'd rather not write a driver for?
[Open an instrument request](https://github.com/ezzatisawesome/guppi/issues/new?template=instrument-request.yml)
with its `*IDN?` string.
