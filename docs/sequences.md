# Buttons & sequences

Dashboard buttons that run multi-step procedures against your rig — power-on
ramps, sweeps, protection checks — without writing a full test plan.

Two kinds of button live on a dashboard:

- **`button`** — fires exactly one device capability (arm, capture, start).
  No parameters, no steps.
- **`sequence`** — runs a short script you write. It can step, dwell, loop,
  read back, prompt the operator, and call other buttons.

This page is about sequences. For saved, repeatable pass/fail tests, use
[OpenHTF test plans](openhtf-authoring-guide.md) instead.

## Writing a sequence

Add a **Sequence** block in dashboard edit mode and open its script editor.
The script is the body of an async JavaScript function; `rig` is in scope and
top-level `await` works. Ask the Guppi agent to write it for you, or start
from this:

```js
await rig.telemetry(true);                              // label + start recording
await rig.send("psu1.1.set_voltage", { value: 32 });
await rig.send("psu1.1.set_current", { value: 5 });
await rig.send("psu1.1.set_output", { enabled: true }); // source ON
await rig.sleep(500);                                   // settle
await rig.send("eload1.1.set_load", { enabled: true }); // load ON
await rig.annotate("DUT enabled");                      // timeline note
await rig.telemetry(false);
rig.log("powered on");
```

A syntax error disables the button and shows on its status line before you
ever run. Scripts run in your browser; each `await rig.send(...)` resolves
after the rig has acted, so steps run strictly in order.

## The `rig` API

| Call | What it does |
|---|---|
| `await rig.send(path, params)` | One device command. Setters take `{value: n}`, enables `{enabled: true}`, no-arg capabilities `{}`. |
| `await rig.read(path)` | Current value of one signal. |
| `await rig.sleep(ms)` | Settle delay. Aborts instantly on Stop. |
| `rig.log(msg)` | Status line in the logs panel (last line shows under the button). |
| `await rig.prompt(msg \| spec)` | Ask the operator. `null` means they cancelled. |
| `await rig.telemetry(true \| false)` | Start (with a label prompt) / stop recording to history. |
| `await rig.annotate(msg)` | Drop a note on the telemetry timeline at this moment. |
| `await rig.run(label)` | Run another sequence button on this board, inline. |

Paths are exact catalog paths — `psu1.1.set_voltage`, `scope1.capture_screenshot`.
Don't invent or drop channel segments; the dashboard's signal picker and the
agent both know the real ones.

### Prompts

A bare string asks for text. Pass a spec for typed input:

```js
const amps = await rig.prompt({ type: "number", message: "Load current (A)",
                                min: 0, max: 5, step: 0.1, default: 1 });
const go   = await rig.prompt({ type: "boolean", message: "Proceed with ramp?" });
const rng  = await rig.prompt({ type: "select",  message: "Range",
                                options: ["0–2 A", "2–5 A"] });
if (amps === null) return;   // operator cancelled
```

### Reading back and branching

```js
await rig.send("load3.set_current", { value: 4.2 });   // over the 3.5 A eFuse
await rig.sleep(500);
if (await rig.read("load3.tripped") === 1) {
  rig.log("✓ eFuse tripped as expected");
} else {
  rig.log("✗ eFuse did NOT trip");
}
```

Verify effects by reading real signals, not by assuming a command worked.

## Composing buttons

Keep each button atomic — one procedure — and build bigger tests by calling
them:

```js
await rig.run("Power On");
await rig.sleep(2000);
await rig.run("Load Ramp");
await rig.run("Protection Check");
```

`rig.run` finds the button by its label, runs its script inline, prefixes its
log lines, and shares one Stop — aborting anywhere ends the whole chain. Only
one sequence runs at a time; calling a button that's already active in the
chain throws (ending the run unless you catch it), so a cycle can't sneak in.
`Promise.all([rig.run("Load A"), rig.run("Load B")])` runs two buttons
concurrently.

## Failures and Stop

- A failed `send` (bad path, device error) rejects the run immediately — no
  later steps fire. Wrap in `try/catch` if you want to clean up:

  ```js
  try {
    await rig.send("load1.set_current", { value: 10 });
  } catch (err) {
    rig.log(`load failed: ${err.message}`);
    await rig.send("load1.set_load", { enabled: false });
  }
  ```

- **Stop** aborts the current `sleep` and refuses to dispatch any further
  commands. It cannot recall a command that already reached the rig — the
  instrument's own protection (OCP/OPP) and the rack watchdog stay in charge
  of the hardware.

Set the source's current limit before energizing anything, and give sensitive
steps settling time.

## Button options

Sequence buttons are **two-step by default**: first press arms, second
confirms (and it auto-disarms after a few seconds untouched). Set
`variant: "instant"` to fire on a single click — only for procedures that are
safe to trigger accidentally. Other options: `label` (the button text and
`rig.run` name) and `hotkey` (a bare key that mirrors a click — `"space"`,
`"s"`, `"f2"`; it arms and confirms just like clicking. `"p"` is taken by
pause-display).

## Not available in scripts

No `fetch`, no filesystem, no DOM — just modern JavaScript plus `rig`. If a
procedure needs measurements with limits and a pass/fail verdict, promote it
to an [OpenHTF test](openhtf-authoring-guide.md).
