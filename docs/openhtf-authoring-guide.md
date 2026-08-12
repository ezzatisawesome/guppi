# Writing OpenHTF tests to Guppi standards

A complete, opinionated guide to authoring OpenHTF test scripts that run well in
the Guppi environment — the contract, the injected vocabulary, the driver API a
test author actually touches, safety layering, performance rules, and a deep
section on driving the **Keysight MP4300 Solar Array Simulator as an irradiance
source**.

This is the practitioner's companion to the two canonical references it never
supersedes:

- `packages/rack/docs/test-authoring.md` — the script contract (source of truth)
- `docs/public/drivers.md` — the driver/instrument layer

---

## 0. Mental model — what actually runs

A Guppi test is **a plain Python file in the rig's workspace under `tests/`**.
There is no test registry and no framework subclass to inherit. The rack:

1. Reads the file from *its own disk* (the workspace) — the script is never
   shipped over the wire with the run command; `test_path` names a file and the
   rack reads it, so an edit between plan-approval and start fails loudly instead
   of running different code silently.
2. `exec()`s it in a locked-down namespace (see §3).
3. Pulls the module-level `TEST_PHASES` list out of the namespace.
4. Builds `htf.Test(*TEST_PHASES)` and calls `test.execute(...)`.
5. Binds every configured rig device as an OpenHTF **plug** — a live, already
   connected driver instance shared across all phases.
6. Streams a run-state document (phases, measurements, prompts, artifacts) to
   NATS as it runs, and persists the final record to Postgres.

Key consequences you must design around:

- **Device instances are server-owned and long-lived.** They are constructed
  once at rack boot and reused across every phase and every run. Plug `tearDown`
  is a deliberate no-op — OpenHTF never disconnects hardware between phases.
  State you set in phase 1 (an output enabled, a curve programmed) is still there
  in phase 2, and still there in the *next* run. This is why teardown discipline
  (§6) matters and why resume-from-phase (§8) works.
- **The plan is derived from your measurements**, not written by hand. The phase
  list + each phase's `@measures` limits become the plan shown in the UI/CLI
  *before* the run starts. Put display truth in the measurement, never in prose.
- **The trust surface is fixed.** Only the names in §3 are injected. Everything
  else is stock Python.

---

## 1. Environment & versioning

| Thing | Value |
|---|---|
| Python | `>= 3.12` |
| OpenHTF | rack pins `openhtf>=1.0`; agent pins `openhtf>=1.6` |
| Transport | pyvisa + pyvisa-py (pure-Python VISA; no NI-VISA needed on a Pi) |
| Where tests live | rig workspace `tests/*.py` (e.g. `/home/guppi/workspace/tests/` on a Pi) |
| Where hardware is declared | `rig_config.yml` (installed at `~/.guppi/rig_config.yml`) |

Two runtime modes, transparent to the script:

- **Local ("Pi") mode** — `agent` backend, LAN-only, no auth, no AI.
- **Cloud mode** — `agent-cloud` backend, guppi.app auth, AI agent can drive and
  answer prompts.

The script you write is identical in both. The rack is outbound-only (dials out
over NATS, never accepts inbound), so you never think about ports or IPs — a rig
is addressed by `rig_id`.

---

## 2. The contract (the smallest correct test)

```python
import openhtf as htf
from openhtf import measures
from openhtf.util import units

@htf.plug(PSU=PSU1)
@measures(htf.Measurement("vout").with_units(units.VOLT).in_range(4.9, 5.1))
def check_rail(test, PSU):
    PSU.set_voltage(1, 5.0)
    PSU.set_output(1, True)
    test.measurements.vout = PSU.measure_voltage(1)

TEST_PHASES = [check_rail]
```

Three rules, and that's the whole contract:

1. **`TEST_PHASES`** — a module-level list of OpenHTF phase functions. That list
   *is* the test. Nothing else is required.
2. **Bind hardware with `@htf.plug(NAME=DEVICE_ID)`** — the config device id,
   uppercased, is injected as a plug class. A device with `id: psu1` in
   `rig_config.yml` is available as `PSU1`; `id: load1` → `LOAD1`; `id: sas1` →
   `SAS1`. The left-hand name (`PSU=`) is just the parameter name inside your
   function.
3. **Declare limits in `@measures`** — `.in_range(lo, hi)`, `.equals(x)`,
   `.with_units(units.VOLT)`, etc. The rack introspects these to derive the plan.
   Building `htf.Test(*TEST_PHASES)` never *executes* a phase, so plan derivation
   is safe even off-hardware.

### How binding works under the hood

OpenHTF binds plugs by *class* and instantiates each with no args. Guppi's
drivers are pre-built, connected instances owned by the server. The executor
bridges this by synthesizing a zero-arg subclass whose `__new__` always returns
the one shared instance:

```python
# packages/rack/src/sequencer/executor.py
def _plug_class_for(driver):
    return type(
        f"{type(driver).__name__}Plug",
        (type(driver),),
        {"__new__": lambda cls: driver, "__init__": lambda self: None},
    )
```

So inside your phase, `PSU` is the actual driver object — you call its Python
methods directly (`PSU.set_voltage(1, 5.0)`), not through any RPC or capability
indirection.

---

## 3. Injected vocabulary — the entire trust surface

The executor's `_build_script_namespace` injects exactly this and nothing more:

| Name | Signature | Use |
|---|---|---|
| `openhtf` / `htf` | — | the OpenHTF module |
| `time` | — | convenience (`time.sleep(...)`) |
| `PSU1`, `LOAD1`, … | — | bound device plug classes (uppercased config ids) |
| `capture_artifact` | `(path, waveform, phase=None) -> ref` | publish a **uniform numeric series** by reference (a scope trace, or one metric of a sweep), stamped with the run's `execution_id`. `waveform` must be `{"v": [floats], "sample_rate": float, "t0"?: float, "unit"?: str}`; **only `v` is stored** (compact f32) and the axis is rebuilt from `(t0, sample_rate, n)`. Any dict lacking `"v"` raises `KeyError`. Raises if no artifact store is configured. |
| `safe_shutdown` | `() -> None` | de-energize every output on the rig. Use in an L2 teardown phase. |
| `arm_guard` | `(path, op, threshold, min_duration=0.0) -> ids` | arm a **run-scoped** watchdog abort-limit (L1). The run's teardown disarms exactly what it armed. |
| `grid` | `(**axes) -> list[point]` | build a Cartesian setpoint matrix |
| `sweep` | `(points, apply, measure, *, settle_s=0.0, on_point=None) -> rows` | drive the matrix: command → settle → measure |
| `prompt` | `(text, kind="confirm") -> Any` | pause the phase and ask a human/agent |

`__builtins__` is present, so normal imports work (you can
`from devices.psu.keysight_mp4300 import SasCurve` — see §9). Keep that power for
data types and stdlib; don't reach around the injected safety vocabulary.

---

## 4. Measurements — the pass/fail contract

Measurements are how a phase declares intent *and* renders pass/fail. Declare the
limit in the decorator; assign the value in the body.

```python
@measures(
    htf.Measurement("vout").with_units(units.VOLT).in_range(4.9, 5.1),
    htf.Measurement("iout").with_units(units.AMP).in_range(0, 0.5),
    htf.Measurement("recovered").equals(True),
)
def characterize(test, PSU):
    test.measurements.vout = PSU.measure_voltage(1)
    test.measurements.iout = PSU.measure_current(1)
    test.measurements.recovered = PSU.measure_voltage(1) > 4.5
```

Rules that keep results clean:

- **Keep measurements scalar.** A measurement value is coerced to a JSON scalar
  (`str()` otherwise). Do **not** assign a list/matrix/waveform to a measurement —
  it flattens to a string. Reduce to a scalar (`min`, `max`, a boolean), and put
  the full data on the artifact plane (§7).
- **One limit, one place.** If the panel should show `4.9–5.1 V`, that range
  lives in `.in_range(4.9, 5.1)`, not in a comment or a `prompt` string.
- **Name measurements stably.** The plan validator compares phase names (ordered)
  and per-phase measurement-name sets between the derived plan and the running
  script; a rename mid-approval trips a loud mismatch, not a silent divergence.

---

## 5. Prompts — collaborative pause points

`prompt()` blocks the phase until answered from the CLI (`guppi run` asks
inline), the web UI (a card on the test panel), or the AI agent. Every prompt —
question, answer, responder, timestamps — is recorded in `prompts[]` of the
run-state doc.

```python
prompt("Confirm the DUT is bolted to the cold plate")        # kind="confirm" → True
soc = prompt("Enter the measured pack SoC (%)", kind="input") # kind="input"   → the string
prompt("Trigger the transient, then continue", kind="action") # kind="action"  → True
```

Guidance:

- Use prompts **only** where the test genuinely needs a human — bench setup, a
  manual stimulus, a value only the operator can read. An unattended run should
  fly through a prompt-free script.
- `guppi run --step` inserts a confirm-gate before *every* phase as a debug
  overlay; those gates never appear in the plan or the result phases.
- A prompt raises `RuntimeError` if the run is aborted while waiting, so it
  cooperates with abort.

---

## 6. Safety — the three layers (design for all three)

Never rely on software to catch a microsecond fault. Layer your protection:

| Layer | Mechanism | Where it lives |
|---|---|---|
| **L0** | the instrument's own current/OCP/OVP limit | set it *first* in your setup phase, or in `rig_config.yml` device kwargs |
| **L1** | watchdog abort-limit — samples telemetry, de-energizes + latches on breach | `rig_config.yml` `safety.abort_limits`, or per-run `arm_guard(...)` |
| **L2** | explicit de-energize on the way out | a teardown phase calling `safe_shutdown()` inside `finally` |

Canonical shape of a phase that energizes:

```python
@htf.plug(PSU=PSU1)
@measures(htf.Measurement("peak_current"))
def stress(test, PSU):
    try:
        PSU.set_current(1, 5.0)                       # L0: hardware current limit first
        arm_guard("psu1.1.current", ">", 5.5, min_duration=0.2)  # L1: run-scoped backstop
        PSU.set_voltage(1, 5.0)
        PSU.set_output(1, True)
        time.sleep(0.5)
        test.measurements.peak_current = PSU.measure_current(1)
    finally:
        safe_shutdown()                              # L2: de-energize no matter what
```

Notes:

- **`arm_guard` is run-scoped.** It records the ids it armed and the run's
  teardown disarms exactly those, so a guard doesn't leak into the next run.
  Persistent guards belong in `rig_config.yml`.
- **Thresholds are signed** for bidirectional supplies. A regenerative supply
  sinking current reads negative — arm one limit per direction (e.g. `>`, `80`
  for source OC and `<=`, `-40` for sink OC).
- **`safe_shutdown()`** invokes every device's `energizing=True` capability with
  `{"enabled": False}` — a guaranteed rig-wide de-energize.

---

## 7. Performance — measure fast signals from the instrument's buffer

A polled read is capped by the SCPI round-trip (1–50 ms, serialized per
instrument) plus the instrument's NPLC integration (~16–20 ms). Realistically a
few Hz to ~100 Hz for a whole device. **Polling faster does not sample faster —
it returns duplicates.**

For anything fast (load transients, inrush, ripple), do not poll. Arm the
instrument's hardware-timed buffer, let it capture on its own clock, then read
the trace back in one transfer and publish it by reference:

```python
@htf.plug(SCOPE=SCOPE1)
def capture_transient(test, SCOPE):
    wave = SCOPE.fetch_waveform(channel=1)      # hardware did the DAQ
    capture_artifact("scope1.transient", wave, phase="capture_transient")
```

The waveform rides the artifact plane (compact f32 + summary stats), joined to
the run by `execution_id`; it never bloats the result JSON. Reserve *polled*
bench reads for the slow, precise tier (setpoints, NPLC-accurate DMM values).

**The `capture_artifact` contract (know this exactly).** The helper accepts a
single **uniform numeric series**, shaped like what `fetch_waveform()` returns:

```python
{"v": [ ... floats ... ],   # required: the values (the only thing stored)
 "sample_rate": <float>,    # required: samples per axis-unit
 "t0": <float>,             # optional: axis start  (default 0.0)
 "unit": "<str>"}           # optional: engineering unit of v
```

Only `v` is encoded (compact f32); the axis is *reconstructed* from
`(t0, sample_rate, n)`, so the stored series is always 1-D and uniformly spaced.
`v` must be a list of floats. **A dict without `"v"` raises `KeyError: 'v'`** —
you cannot hand `capture_artifact` a `{"rows": ...}` matrix, an arbitrary JSON
blob, or a list of dicts. To persist a multi-metric sweep, publish **one series
per metric** (§8). Scalars and metadata belong in measurements, not the artifact.

---

## 8. Sweeps and resume

### Declarative sweeps

Use `grid` + `sweep` instead of hand-writing nested loops — you get a
structured, dimensioned result and the loop can't drift from the plan.

```python
def series(rows, key):
    """One metric column from sweep() rows, as a plain float list."""
    return [float(r["values"][key]) for r in rows]


@htf.plug(PSU=PSU1, LOAD=LOAD1)
@measures(htf.Measurement("vout_min").with_units(units.VOLT).in_range(4.9, 5.1))
def characterize(test, PSU, LOAD):
    rows = sweep(
        grid(vin=[20, 28, 36], iout=[0.5, 1.0]),   # row-major, first axis outer
        apply=lambda p: (PSU.set_voltage(1, p["vin"]), LOAD.set_current(1, p["iout"])),
        measure=lambda p: {"vout": PSU.measure_voltage(1)},
        settle_s=0.2,                               # wait between apply and measure
    )
    # rows = [{point, values, t_ms}, ...]. Persist ONE numeric series per metric —
    # capture_artifact stores a uniform 1-D array, not a matrix (§7).
    capture_artifact(
        "sweep.characterize.vout",
        {"v": series(rows, "vout"), "sample_rate": 1.0, "t0": 0.0, "unit": "V"},
        phase="characterize",
    )
    test.measurements.vout_min = min(r["values"]["vout"] for r in rows)
```

`sweep` is sequential by construction (command → settle → measure) — the correct,
reproducible ordering for qualification. **Do not assign the row list to a
measurement** (§4), and **do not hand it to `capture_artifact` as `{"rows": …}`** —
that raises `KeyError: 'v'` (§7). Persist each metric as its own series.

**Choosing the series axis.** `capture_artifact` reconstructs a uniform axis from
`(t0, sample_rate, n)`:

- **1-D sweep over a uniform axis** — encode the real axis. For
  `grid(irradiance_pct=[20, 40, 60, 80, 100])` the step is 20, so
  `t0=20.0, sample_rate=1.0/20.0` (samples per %-irradiance) rebuilds
  `20, 40, 60, 80, 100`.
- **Multi-axis grid (or a non-uniform axis)** — there is no single uniform axis,
  so publish against the **row index**: `t0=0.0, sample_rate=1.0`. Rows stay in
  `grid`'s row-major order (first axis outer), and the swept setpoints are already
  captured per row in `rows[i]["point"]`.

### Resuming a failed run

A finished run can be re-run from a phase onward — the "resume from here" button
on a failed phase, or `resume_from_phase` on the run command. The rack slices
`TEST_PHASES` from the named phase; because device plugs are server-owned and
keep their state across runs, earlier phases needn't repeat. It is a new
execution with its own id; the plan still describes the whole test, so skipped
phases read as skipped. **Design phases so a later one can start from the state a
former one left** (or make each phase re-establish what it needs).

---

## 9. The MP4300 Solar Array Simulator as an irradiance source

This is the section you came for. The `KeysightMP4300` driver
(`packages/rack/src/devices/psu/keysight_mp4300.py`) turns a Keysight MP4300
mainframe into a photovoltaic source your DUT (an MPPT charger, a power board,
a bus converter) sees as a real solar array.

### 9.1 How irradiance maps onto the SAS

A PV panel's I–V curve is defined by four points, and irradiance/temperature move
them in physically specific ways:

| PV parameter | Driver field | Moves with… |
|---|---|---|
| **Isc** — short-circuit current | `isc` | **Irradiance — linearly.** 1000 W/m² → full Isc; 500 W/m² → ~half Isc. This is your primary irradiance knob. |
| **Imp** — current at max-power point | `imp` | Irradiance, ~linearly (tracks Isc). |
| **Voc** — open-circuit voltage | `voc` | Irradiance weakly (logarithmic); **temperature** strongly (negative tempco). |
| **Vmp** — voltage at max-power point | `vmp` | Mostly temperature. |

So there are two clean ways to drive irradiance, and you'll typically use both:

1. **Current scale factor (fast irradiance knob).** `set_current_scale(ch, pct)`
   scales the *whole programmed curve's current* by 1–100 %. Program the curve
   once at full sun (100 %), then treat the scale percentage as **irradiance in
   percent of STC**: 100 % = 1000 W/m², 20 % = 200 W/m². No curve re-validation,
   just a single SCPI write — ideal for an irradiance sweep or a moving-cloud
   profile. Pair it with `set_voltage_scale(ch, pct)` to model the temperature
   axis (Voc/Vmp) independently.

2. **Reprogram the full curve.** `set_sas_curve(ch, SasCurve(voc, isc, vmp, imp))`
   writes a new four-point curve atomically. Use this when you want physically
   correct Voc *and* Isc for a specific (irradiance, temperature) operating point
   — e.g. converting a datasheet's per-irradiance curves directly.

### 9.2 Hard limits — the module capability envelopes

An MP4300 is a *mainframe* holding **heterogeneous** SAS modules; **each installed
module is one channel**, addressed inline as `(@ch)`. At connect the driver reads
`*RDT?` to learn which slots are populated and with which model, then selects that
slot's envelope. Curves and limits are validated against the **per-slot** envelope
— never a single mainframe-wide number.

`MODULE_LIMITS` table (from the MP4300 Operating & Service Guide "Power Module
Output Quadrants" + the MP4300A data sheet):

| Model | Voc/Vmp max | Isc/Imp max | Power max | Quadrants | Sink max | Ranging |
|---|---|---|---|---|---|---|
| **MP4361A** | 160 V | 10 A | 1000 W | 2-quadrant | −10 A | autoranging |
| **MP4362A** | 130 V | 8 A | 1000 W | single (source-only) | −0.5 A | fixed |
| **MP4351A** | 160 V | 10 A | 1400 W | 2-quadrant | −10 A | autoranging |
| **MP4352A** | 80 V | 20 A | 1400 W | 2-quadrant* | −20 A | autoranging |

\* The guide prints "??" for the MP4352A's 2-quadrant cell; the driver treats it
as 2-quadrant but **confirm sink behaviour on real hardware before relying on
it.** The default envelope (no detection, no config override) is the MP4361A.

**Curve validity rules** enforced client-side by `validate_sas_curve` *before*
the write (a curve that violates these raises `ValueError`, so you catch it in
Python rather than having the mainframe silently reject it):

- All four parameters `>= 0`.
- `Vmp <= Voc` and `Imp <= Isc`.
- `Isc >= max(0.1 % of the module's Isc_max, 10 mA)` — below the module's minimum
  representable short-circuit current the mainframe rejects the curve, lights ERR,
  and **silently keeps the previous curve**. This is the footgun the client-side
  check exists to catch.
- Each of `Voc, Vmp, Isc, Imp` within the module max.
- `Pmp = Vmp × Imp <= module p_max`.

**Silent-rejection guard.** Even after the client check, `set_sas_curve` drains
`SYSTem:ERRor?` before and after the write and **raises if the mainframe logged a
rejection** — because an invalid curve is otherwise accepted-looking while the old
curve stays active. Trust the exception; don't assume a write "took".

**Scale factors:** `set_current_scale` / `set_voltage_scale` accept **1–100 %**
only (values outside raise). You cannot scale to 0 % — to kill the array, turn the
output off (`set_output(ch, False)`), don't scale to zero.

**Other envelope-bounded setters** (each validates against the per-slot module):

- `set_current_limit(ch, A)` — positive limit, `<= isc_max` (voltage priority).
- `set_current_limit_negative(ch, A)` — sink limit magnitude, `<= sink_current_max`.
  A source-only module (MP4362A) rejects anything beyond −0.5 A.
- `set_voltage_limit(ch, V)` / `set_voltage_limit_low(ch, V)` — `<= voc_max`.
- `set_power_limit(ch, W)` — `<= p_max`. Caps one module so the *summed* frame
  power can't trip the mainframe **FPL** (which drops **all** outputs).
- `set_ovp(ch, V)`, `set_ocp(ch, A)` — programmable protection. **OCP applies in
  SAS mode**; in Fixed mode the mainframe ignores it and enforces the current
  limits instead.

### 9.3 Modes, settling, and faults you must handle

- **Mode:** `set_mode(ch, "SAS")` for curve operation (what you want for
  irradiance), `set_mode(ch, "FIX")` for a plain fixed-V/I supply.
- **Regulation priority (Fixed mode only):** `set_priority_mode(ch, "VOLT"|"CURR")`.
- **SAS compensation bandwidth:** `set_sas_bandwidth(ch, mode)` where mode is
  `DEFAULT | FAST_LOWC | FAST_HIGHC | SHUNTSW`. **Match this to your DUT converter's
  input capacitance/topology** — the wrong mode can oscillate the SAS loop. For an
  MPPT DC-DC charger, `FAST_LOWC`/`FAST_HIGHC` are the usual choices; `DEFAULT` is
  the widest-tolerance fallback.
- **Settling:** command ack is ≤1 ms but the output settles in ~100 ms. Before a
  dependent readback, call `PSU.wait_operation_complete()` (`*OPC?`) or
  `time.sleep(0.1)`. The telemetry sampler polls continuously and doesn't need it.
- **Realised vs requested curve:** the module fits an exponential model, so the
  *realised* Vmp/Imp can differ from what you asked (Isc/Voc are exact). Read back
  what the DUT actually sees with `get_actual_sas_curve(ch)`.
- **Faults / latches:**
  - `channel_conditions(ch)` decodes live status to named flags (`OV`, `OC`, `OT`,
    `CV`, `CC`, `FLT`, …).
  - `clear_output_protection(ch)` clears most trips (OVP/OCP/OT) — **but `FLT` is a
    hardware-fault latch that only a power cycle clears.** The driver logs if `FLT`
    is still set after a clear.
  - Frame-level faults (`frame_faulted` telemetry signal / `frame_conditions()`):
    fan, over-temp, missing lockout bar, input power fail, or **FPL** (summed power
    exceeded) — any of these takes down every channel.
  - **Blocking diode:** `set_diode_mode(ch, True)` inserts a reverse-current
    blocking diode; with it engaged the channel **cannot sink current**, negative
    limits/setpoints are invalid, and voltage readback carries a ~0.7 V anode
    offset. Switching it reverts the module to `*RST` (drops the output) — set it in
    setup, not mid-run.

### 9.4 Telemetry signals the MP4300 streams

Per installed channel: `{ch}.voltage`, `{ch}.current`, `{ch}.output`,
`{ch}.voltage_setpoint`, `{ch}.current_setpoint`, `{ch}.protection_tripped`,
`{ch}.diode_mode`, `{ch}.thermal_margin_c`. Rig-wide: `frame_faulted`.

`thermal_margin_c` is worth watching in a long irradiance-at-full-power run: the
module derates current 1 %/°C above 40 °C ambient, so a shrinking margin predicts
an OT trip before it happens — arm an `arm_guard` on it and back off rather than
react to the trip. Abort-limit paths use the `sasN.<signal>` form (e.g.
`sas1.1.current`, `sas1.frame_faulted`).

### 9.5 `rig_config.yml` for the SAS

```yaml
devices:
  - id: sas1                      # → plug SAS1 in tests
    name: "MP4300 Solar Array Sim"
    type: KeysightMP4300
    enabled: true
    num_channels: 2               # declare installed count; *RDT? confirms at connect
    rate_hz: 5                     # SAS health moves slowly; a few Hz is plenty
    connection:
      type: VISA
      address: "TCPIP0::192.168.1.50::inst0::INSTR"
      timeout: 10.0
    # Optional: pin the envelope explicitly to DISABLE auto-detection.
    # Omit to let *RDT? pick each slot's module envelope automatically.
    # module_limits: { voc_max: 160, isc_max: 10, p_max: 1000 }

safety:
  abort_limits:
    - { path: sas1.1.current, op: ">=", threshold: 10, min_duration: 0.1,
        label: "sas1 ch1 over-current" }
    - { path: sas1.frame_faulted, op: ">=", threshold: 1,
        label: "sas1 mainframe fault" }
```

If you pin `module_limits` or `channel_limits` in config, that is authoritative
and detection leaves the bounds alone (mirrors the RP5900 driver). Omit them to
let `*RDT?` select the correct per-slot envelope.

### 9.6 End-to-end: an irradiance sweep on a DUT

This programs a full-sun curve once, then steps irradiance via the current scale
factor and records how the DUT's harvested power tracks — the canonical MPPT /
power-board qualification.

```python
"""Irradiance sweep — hold a fixed panel curve, step irradiance 20→100 %,
and verify the DUT keeps harvesting near the max-power point at each level."""

import openhtf as htf
from openhtf import measures
from openhtf.util import units
from devices.psu.keysight_mp4300 import SasCurve   # __builtins__ import allowed

CH = 1
# One panel's STC (full-sun) curve. Within the MP4361A envelope
# (160 V / 10 A / 1 kW): Pmp = 32.4 V * 8.6 A = 279 W. OK.
STC = SasCurve(voc=38.0, isc=9.1, vmp=32.4, imp=8.6)

# Irradiance axis: 20 % steps starting at 20 %. Encoding it as (t0, sample_rate)
# lets each published series carry the real x-axis (see §8).
IRR_STEP_PCT = 20.0
IRR_AXIS = {"t0": IRR_STEP_PCT, "sample_rate": 1.0 / IRR_STEP_PCT}  # samples per %


def series(rows, key):
    """One metric column from sweep() rows, as a plain float list."""
    return [float(r["values"][key]) for r in rows]


@htf.plug(SAS=SAS1)
def setup_array(test, SAS):
    # Order matters: mode → compensation → curve → protection → enable.
    SAS.set_mode(CH, "SAS")
    SAS.set_sas_bandwidth(CH, "FAST_LOWC")     # match the DUT's MPPT input stage
    SAS.set_sas_curve(CH, STC)                 # raises if rejected — trust it
    SAS.set_current_scale(CH, 100.0)           # start at full sun
    SAS.set_ocp(CH, 9.5)                        # L0 above Isc, below module max
    SAS.set_power_limit(CH, 350.0)             # keep the frame under FPL
    arm_guard("sas1.frame_faulted", ">=", 1)   # L1 backstop on frame health
    SAS.set_output(CH, True)
    SAS.wait_operation_complete()


@htf.plug(SAS=SAS1)
@measures(
    # Reduce the matrix to scalar pass/fail; the full matrix goes to an artifact.
    htf.Measurement("harvest_at_full_sun_w").with_units(units.WATT).in_range(240, 300),
    htf.Measurement("min_harvest_ratio").in_range(0.85, 1.0),
)
def irradiance_sweep(test, SAS):
    rows = sweep(
        grid(irradiance_pct=[20, 40, 60, 80, 100]),
        apply=lambda p: SAS.set_current_scale(CH, p["irradiance_pct"]),
        measure=lambda p: {
            "v": SAS.measure_voltage(CH),
            "i": SAS.measure_current(CH),
            "p": SAS.measure_power(CH),
            # Available max power at this irradiance = scaled Pmp of the curve.
            "p_avail": STC.pmp() * p["irradiance_pct"] / 100.0,
        },
        settle_s=0.3,   # SAS output settle + DUT MPPT re-track
    )
    # One uniform series per metric (§7); the irradiance axis rides (t0, sample_rate).
    for metric, unit in (("p", "W"), ("v", "V"), ("i", "A"), ("p_avail", "W")):
        capture_artifact(
            f"sas1.irradiance_sweep.{metric}",
            {"v": series(rows, metric), "unit": unit, **IRR_AXIS},
            phase="irradiance_sweep",
        )

    full_sun = next(r for r in rows if r["point"]["irradiance_pct"] == 100)
    test.measurements.harvest_at_full_sun_w = full_sun["values"]["p"]
    test.measurements.min_harvest_ratio = min(
        r["values"]["p"] / r["values"]["p_avail"] for r in rows
    )


@htf.plug(SAS=SAS1)
def teardown(test, SAS):
    safe_shutdown()   # de-energizes SAS (and everything else) via L2

TEST_PHASES = [setup_array, irradiance_sweep, teardown]
```

Why it's built this way:

- **Curve programmed once, irradiance via scale** — one SCPI write per step, no
  per-step curve re-validation, physically correct (Isc scales with irradiance).
- **`FAST_LOWC` compensation** chosen for an MPPT DC-DC input — prevents SAS-loop
  oscillation. Change to match your actual converter.
- **`settle_s=0.3`** covers both the SAS output settle (~100 ms) *and* the DUT's
  MPPT re-tracking after each irradiance step — tune to your DUT.
- **Scalar measurements, one series per metric** — the sweep rows would flatten to
  a string if assigned to a measurement, so each metric (`p`, `v`, `i`, `p_avail`)
  rides the artifact plane as its own uniform series, and only the reduced scalars
  (`harvest_at_full_sun_w`, `min_harvest_ratio`) carry limits. `capture_artifact`
  stores a 1-D array, never a `{"rows": …}` matrix (§7).
- **All three safety layers**: OCP/power-limit (L0), `arm_guard` on frame health
  (L1), `safe_shutdown()` in a teardown phase (L2).

### 9.7 Modeling irradiance *and* temperature together

If you need a full (irradiance, temperature) operating grid with physically
correct Voc and Vmp at each point, reprogram the curve per point instead of
scaling. Precompute the four points from your panel model / datasheet:

```python
@htf.plug(SAS=SAS1)
@measures(htf.Measurement("min_harvest_ratio").in_range(0.85, 1.0))
def irradiance_temp_grid(test, SAS):
    rows = sweep(
        grid(irradiance_wm2=[400, 700, 1000], cell_temp_c=[15, 45, 70]),
        apply=lambda p: SAS.set_sas_curve(CH, panel_curve(p["irradiance_wm2"],
                                                           p["cell_temp_c"])),
        measure=lambda p: {"p": SAS.measure_power(CH),
                           "p_avail": panel_curve(p["irradiance_wm2"],
                                                  p["cell_temp_c"]).pmp()},
        settle_s=0.4,
    )
    # A 2-D grid has no single uniform axis, so publish each metric against the
    # row index (t0=0, sample_rate=1). Rows stay row-major — irradiance outer,
    # temperature inner — and each row's setpoints live in rows[i]["point"].
    # `series` is the helper from §8/§9.6.
    idx_axis = {"t0": 0.0, "sample_rate": 1.0}
    capture_artifact("sas1.irr_temp_grid.p",
                     {"v": series(rows, "p"), "unit": "W", **idx_axis},
                     phase="irradiance_temp_grid")
    capture_artifact("sas1.irr_temp_grid.p_avail",
                     {"v": series(rows, "p_avail"), "unit": "W", **idx_axis},
                     phase="irradiance_temp_grid")
    test.measurements.min_harvest_ratio = min(
        r["values"]["p"] / r["values"]["p_avail"] for r in rows)
```

where `panel_curve(irradiance, temp)` returns a validated `SasCurve` (Isc ∝
irradiance; Voc down with temperature via the panel tempco). Each write is
atomically validated against the module envelope, so an out-of-envelope
(irradiance, temp) point fails loudly at that step.

---

## 10. Checklist — is this test "up to Guppi standards"?

- [ ] `TEST_PHASES` is a module-level list of phase functions.
- [ ] Every device bound with `@htf.plug(NAME=DEVICE_ID)`; ids match `rig_config.yml`.
- [ ] Every pass/fail limit lives in an `@measures(...)` decorator, not in prose.
- [ ] Measurements are scalar; each waveform/sweep metric goes through
      `capture_artifact` as its own uniform series (`{"v", "sample_rate", …}`) —
      never a `{"rows": …}` matrix.
- [ ] Any energizing phase sets L0 hardware limits first, arms an L1 `arm_guard`,
      and de-energizes in an L2 teardown `finally` / teardown phase.
- [ ] Fast signals are captured from a hardware buffer, not polled in a loop.
- [ ] Test matrices use `grid`/`sweep`, not hand-rolled nested loops.
- [ ] Prompts appear only where a human is genuinely required.
- [ ] Phases are resume-safe (a later phase can start from the state a former
      one left, or re-establishes what it needs).
- [ ] For the MP4300: mode → bandwidth → curve → protection → enable, in that
      order; curves stay inside the per-slot module envelope; `set_sas_curve`
      exceptions are trusted; `wait_operation_complete()` before dependent
      readbacks; `frame_faulted`/`thermal_margin_c` watched on long runs.

---

## Reference index

| Topic | File |
|---|---|
| Script contract (source of truth) | `packages/rack/docs/test-authoring.md` |
| Executor / namespace / plug binding | `packages/rack/src/sequencer/executor.py` |
| Sweep helpers | `packages/rack/src/sequencer/sweep.py` |
| Run-state doc bridge | `packages/rack/src/sequencer/state_bridge.py` |
| Plan derivation + validation | `packages/rack/src/sequencer/plan.py` |
| Run-state / plan schema | `contracts/test-plan-schema.json` |
| Driver base classes | `packages/rack/src/devices/core/device.py` |
| Driver authoring | `docs/public/drivers.md` |
| Rig config reference | `docs/public/rig-config.md` |
| **MP4300 SAS driver** | `packages/rack/src/devices/psu/keysight_mp4300.py` |
| Example tests | `packages/rack/examples/` |
</content>
</invoke>
