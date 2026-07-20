# Configuring your rig (`rig_config.yml`)

The rack reads one YAML file at startup (default `rig_config.yml`, or the path in
the `RIG_CONFIG_PATH` env var). It describes **what instruments are on the bench,
how they connect, and what safety limits back them up**. Everything lives under a
single top-level `rig:` key.

```yaml
rig:
  id: "rig1"
  name: "Production Test Rack"
  telemetry: { measurement_interval: 0.1, enabled: true }
  devices: [ ... ]
  safety:   { abort_limits: [ ... ] }
  ethernet: { enabled: true }
  drivers:  [ ... ]
```

## Top-level sections

| Key | Purpose | Default |
| --- | --- | --- |
| `id` | **Required.** Unique rig identifier. Every telemetry/command broker topic is namespaced by it, so it must match the id the agent addresses the rig by. Overridden by the `GUPPI_RIG_ID` env var once a rig is paired. | — |
| `name`, `description` | Cosmetic labels shown in the UI. | — |
| `telemetry` | `measurement_interval` (seconds between samples) and `enabled`. | interval `0.1` |
| `devices` | The instruments on the bench (see below). | `[]` |
| `safety` | L1 watchdog abort-limits (see below). | none |
| `ethernet` | Bring the rack onto networked instruments' subnets (see below). | enabled |
| `auto_discover_instruments` | Run the startup VISA/LAN scan and merge in undeclared instruments. | `true` |
| `drivers` | Filesystem paths to **custom** driver code (see below). | `[]` |

> The old `instruments:` key is **deprecated** — use `devices:`. The loader raises
> if it sees `instruments:`.

## Devices

Each entry describes one instrument. There are two shapes, chosen by whether the
entry has a `connection:` block.

### Shape 1 — rack-managed transport (standard SCPI instruments)

The **rack** opens the connection, wraps it in a SCPI codec, and hands that to the
driver. Use this for any bench instrument you talk to over VISA (USB/LAN/serial).

```yaml
- id: psu1                       # required, unique (ids "system"/"execution"/"artifact" are reserved)
  name: "BK9130 Power Supply"    # required
  type: BK9130                   # required — a registered driver name
  enabled: true                  # default true; false skips the device at load
  num_channels: 2                # driver-specific (multi-channel PSUs/loads)
  rate_hz: 10                    # optional per-device sample rate (else telemetry.measurement_interval)
  role: device                   # semantic tag: device (equipment) | dut (thing under test)
  connection:
    type: VISA                   # VISA | SIM | <registered transport>
    address: "USB0::0xFFFF::0x9130::...::INSTR"
    timeout: 10.0                # seconds
    # read_termination / write_termination: forwarded to the backend, needed for
    # raw ::SOCKET instruments that carry no framing of their own.
```

### Shape 2 — driver-owned transport (CAN/I²C/SPI/HTTP boards, DUTs)

No `connection:` block. The **driver instance owns its own link** — it opens,
holds, and closes the connection itself inside `connect()`. The rack just
constructs the driver with the leftover keys (matched to the driver's `__init__`
parameters **by name**) and calls `connect()`.

```yaml
- id: pb1
  name: "Solar-plane PowerBoard"
  type: PowerBoard
  role: dut
  discover: true                 # signals arrive from a runtime manifest (hot-plug/async)
  can_device: auto               # driver kwargs: PowerBoard(can_device=..., bitrate=..., node_id=...)
  bitrate: 1000000
  node_id: 20
```

**Rule of thumb:** SCPI over USB/LAN/serial → Shape 1. Anything with its own
protocol/framing → Shape 2.

Any device key the loader doesn't recognize (`port`, `can_device`, `bitrate`,
`channel_limits`, …) is passed straight to the driver, so driver-specific config
flows through without the loader needing to know about each driver.

## Custom driver code — `drivers:`

`drivers:` is **not** about connections. It's a list of filesystem paths where
**custom driver classes** are loaded from (a `.py` file or a package directory,
resolved relative to the config file). A device's `type:` is looked up by name in
the resulting registry.

You only need this for **out-of-tree** drivers. In-tree drivers (BK9130, Chroma,
Keysight RP5900, ITECH IT-M3900C, SimPSU, …) are always available and need no
entry. One driver class serves many device instances, so the code lives in one
shared registry, referenced by `type:` — it is not nested under a device.

```yaml
drivers:
  - "../../../solar-airplane-fsw/tools/dut-driver"   # a DUT driver shipped with the firmware repo
```

See [drivers.md](drivers.md) to write one.

## Networked instruments — `ethernet:`

A LAN/LXI instrument often ships with a **fixed static IP on an arbitrary subnet**
that the Pi's Ethernet port has no address on — so it's simply unreachable. The
`ethernet:` block makes the rack bring itself onto those subnets automatically at
boot: it ensures a route for declared `TCPIP` devices, passively sniffs the wire
to hear instruments announce themselves, and adds a matching **add-only** IP alias
per subnet. It never runs DHCP, NAT, or a gateway, and every alias is torn down on
shutdown.

```yaml
ethernet:
  enabled: true                  # default true
  iface: eth1                    # optional — pin a dedicated port; unset = auto-pick (never the uplink)
  discovery_seconds: 5.0         # how long to passively sniff
```

Omit the block entirely if your rig is all USB — it defaults on but finds nothing
to do. It's gated behind `auto_discover_instruments`, so turning discovery off
turns this off too.

## Safety abort-limits — `safety:`

The **L1 safety watchdog** is an always-on, local, deterministic backstop. Each
armed limit is a comparison `value <op> threshold` against a live telemetry value.
On a sustained breach the watchdog, in order:

1. **de-energizes** every output (the guarantee),
2. **aborts** the running test (best-effort),
3. emits `system.safety_tripped` and **latches** until cleared.

It backstops *slow, sustained* faults (thermal, sustained over-limit) — its
response is bounded by the sample cadence. **Fast faults are the instrument's own
OCP/current-limit (L0)**, not this loop.

```yaml
safety:
  abort_limits:
    - path: psu1.1.current       # <device>.<channel>.<signal> — a live telemetry path
      op: ">="                   # one of  >  >=  <  <=
      threshold: 30              # SIGNED (see below)
      min_duration: 0.2          # optional — seconds the breach must persist (default 0 = instant)
      label: "psu1 ch1 over-current"   # optional — for logs/UI
      id: "psu1-oc"              # optional — auto-derived from path+op+threshold if omitted
```

Limits are armed at boot. A test can also arm its own scoped limits at runtime;
those are additive.

### Bidirectional supplies: one limit per direction

Regenerative/bidirectional supplies — **Keysight RP5900** and **ITECH IT-M3900C**
— report current and power **signed by quadrant**: *positive while sourcing*,
*negative while sinking*. The comparison is signed, which is exactly what lets you
limit the two directions independently — and you should, because a supply's
**source and sink ratings are different numbers** (it may safely source 80 A but
only sink 40 A). A single "magnitude" limit can't express that; two directional
limits can:

```yaml
safety:
  abort_limits:
    # Source over-current: trips at +80 A
    - { path: psu3.1.current, op: ">=", threshold:  80, label: "psu3 ch1 source OC" }
    # Sink over-current: trips at −40 A
    - { path: psu3.1.current, op: "<=", threshold: -40, label: "psu3 ch1 sink OC" }
    # Same idea for power (source/sink watt ratings differ):
    - { path: psu3.1.power, op: ">=", threshold:  4000, min_duration: 0.2, label: "psu3 ch1 source OP" }
    - { path: psu3.1.power, op: "<=", threshold: -2000, min_duration: 0.2, label: "psu3 ch1 sink OP" }
```

A **unipolar** signal — a source-only PSU's current, a voltage, a temperature —
just uses the one direction that matters (`op: ">="` for an upper ceiling,
`op: "<="` for a lower floor).

> **Why not a single `abs`/magnitude limit?** Because the sink and source ratings
> differ, one magnitude threshold would either trip too early in the
> higher-rated direction or too late in the lower-rated one. Two signed limits
> give each direction its own correct threshold, and still let you arm only one
> direction if that's all that's dangerous.

### Validate before you run

```bash
guppi rack config check      # validates the config (ids, driver types, YAML) without connecting
```
