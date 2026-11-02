# How a test runs

Three nouns. A **Test** is a Python file. Running it makes a **Run**. Everything
anyone said while it ran is in the **Log**. This page is the whole loop on one
screen; the links go deeper.

## Write

A test is a plain OpenHTF file in the rig's workspace under `tests/`. The whole
contract is three lines: bind hardware with `plugs`, declare limits on
measurements, define one `htf.Test` at the bottom.

```python
import openhtf as htf
from openhtf.util import units
from guppi import plugs, safe_shutdown

@htf.plug(psu=plugs.PSU1)
@htf.measures(htf.Measurement("vout").with_units(units.VOLT).in_range(4.9, 5.1))
def check_rail(test, psu):
    try:
        psu.set_voltage(1, 5.0)
        psu.set_output(1, True)
        test.measurements.vout = psu.measure_voltage(1)
    finally:
        safe_shutdown()

test = htf.Test(check_rail)
```

`plugs.PSU1` is the live, already-connected driver for the device with
`id: psu1`. You never connect or disconnect anything. A measurement with a
limit is the verdict: in range passes, out of range fails the phase and the
run. Put it in the workspace with `guppi put tests/check_rail.py`, or write it
there directly on the bench. The full authoring guide is
[Writing tests](openhtf-authoring-guide.md); the short version is the
`write-openhtf-test` skill.

## Run

From the app, open the **Test** panel, pick the test, type a DUT serial if you
have one, press **Run**. From a terminal:

```
guppi run check_rail --dut SN-0042
```

Either way the rack reads the file from its own disk, builds the test and runs
it. The run starts recording by itself: the instruments' telemetry, the test's
measurements and the log all land in history for the run's window, with no
Record button involved. (If a recording was already open, the run joins it.)

## Watch

The Test panel shows the phase rail from the first second, measurements
filling in against their limits, and a card for every `prompt()` the test asks.
Answer it there, in the terminal, or let an agent answer; first answer wins.
**Abort** stops the run: the phase's `finally` runs, and if it cannot exit the
rack de-energises the rig itself.

## Verdict

PASS, FAIL, ERROR or ABORTED. On a fail the failing measurement is named with
its value and limit; on an error, the traceback points into your script. The
terminal exits `0`, `1`, `2`, `3` in that order and prints a link that opens the
run in the app:

```
✔ PASS  (execution 69958239)
  <app>/?rig=rig-bedf7ff7&run=69958239-…&open=run
```

(`<app>` is the web app the hub reports; see [CLI reference](cli.md).)

## Log

There is one log. Every line carries a **source**: `test` (your own
`test.logger` lines and OpenHTF's), `rack` (the sequencer, safety, telemetry)
or `instrument` (driver traffic, the SCPI writes and queries). The Test panel
shows it under the run's phases, filtered to test + rack; two toggles add instrument traffic and debug.
Instrument traffic is DEBUG and is only produced when a device's entry in
`rig_config.yml` sets `log_scpi: true`; leave it off unless you are debugging
a driver, since a polled scope writes several lines per tick.
The same lines are the `system.log` channel in a data view, time-aligned with
the readings, and they are stored whether or not anything is recording.

```
guppi runs 69958239 --bundle        # run.json, measurements.csv, run.log, scope/
guppi query psu1.1.voltage system.log --since <started_at> --until <completed_at>
```

## Timeline

A run is a window over the history. There is one place a run is shown: the
**Test panel**. It follows the rig's live run; in the Runs panel, click any run
to show it there instead (verdict, facts, phases, log), and **‹ Tests** goes
back. Double-click a run to park every lane of the data view on its window
(*Data view* in the Test panel does the same). The link above does both for
anyone. From there, the data view is the
place to see what every instrument did, with the log as a track under the
traces. [Dashboards & data views](dashboards.md) covers the rest.
