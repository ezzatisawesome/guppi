# Buttons & sequences

Dashboard buttons that run multi-step procedures on your rig — power-on
ramps, sweeps, protection checks — without writing a full test plan.

Two kinds of button live on a dashboard:

- **`button`** — fires exactly one device capability (arm, capture, start).
  No parameters, no steps. With `variant: "momentary"` it sends `true` on
  press and `false` on release instead, for a jog or a hold-to-run.
- **script button** (a `button` with a `script`; called `sequence` before) —
  runs a short script you write. It can step, dwell, loop, read back, prompt
  the operator, and call other buttons.

This page is about sequences. For saved, repeatable pass/fail tests, use
[OpenHTF test plans](openhtf-authoring-guide.md) instead.

## Writing a sequence

Add a **Script button** block in dashboard edit mode and open its script editor.
The script is the body of an async JavaScript function; `rig` is in scope and
top-level `await` works. Start from this:

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
ever run. Scripts run in your browser. Each `await rig.send(...)` resolves
after the rig has acted, so steps run strictly in order.

## The `rig` API

| Call | What it does |
|---|---|
| `await rig.send(path, params)` | One device command. Setters take `{value: n}`, enables `{enabled: true}`, no-arg capabilities `{}`. |
| `await rig.read(path)` | Current value of one signal. |
| `await rig.sleep(ms)` | Settle delay, in **milliseconds**. Aborts instantly on Stop. |
| `rig.log(msg)` | Status line in the logs panel (last line shows under the button). **Synchronous — don't `await` it.** |
| `await rig.prompt(msg \| spec)` | Ask the operator. `null` means cancelled, stopped, or superseded by a later prompt — treat it as "don't proceed". |
| `await rig.telemetry(true \| false)` | Start (with a label prompt) / stop recording to history. Cancelling the label prompt skips recording and the script carries on. |
| `await rig.annotate(msg)` | Drop a note on the telemetry timeline at this moment. Blank text does nothing. |
| `await rig.run(label)` | Run another button on this board, inline (by label or node id). |

`read` returns a signal's value. A command that answers with data returns it
as `.result` — e.g. any scope measurement:

```js
const r = await rig.send("scope1.measure", { measurement: "vpp", channel: 1 });
rig.log(`ch1: ${r.result.value} ${r.result.unit}`);   // value is null if the scope can't measure it
```

On a Keysight InfiniiVision scope, `measure` takes `vavg`, `vrms`, `vrms_ac`,
`vpp`, `vmax`, `vmin`, `vamplitude`, `vtop`, `vbase`, `overshoot`, `preshoot`,
`frequency`, `period`, `rise`, `fall`, `pwidth`, `nwidth`, `duty`, `nduty`;
`measure_between` takes `delay` or `phase` with `channel` and `channel2`; and
`query` runs any read-only SCPI query (`{ command: ":MEASure:VPP? FUNCtion" }`
→ `.result.response`). Measurements run on what is on screen, so set the
timebase first.

There is no batched read and no
`waitFor(condition)` — to wait on a state, loop `read` + `sleep` with a bounded
number of tries and fail if it never arrives.

Paths are exact catalog paths — `psu1.1.set_voltage`, `scope1.capture_screenshot`.
Don't invent or drop channel segments; the dashboard's signal picker and the
agent both know the real ones.

**Nothing validates a path inside a script.** `guppi push --check` reads a
page's bound fields, not its script text, so a typo in `rig.send(...)` uploads
clean and fails at click time. Copy each path from the picker or
`guppi catalog`. (For the same reason, a script button's `write` field is dead
weight — it never fires, but it *is* still signal-checked, so a stale one can
fail a push for a field that does nothing. Drop it.)

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

`rig.run` finds the button by its label — or its node id — runs its script
inline, prefixes its log lines, and shares one Stop, so aborting anywhere ends
the whole chain. On duplicate labels the first match on the board wins. It
throws if there is no such button, or if the target's own script has a syntax
error.

Calling a button that's already active in the chain throws (ending the run
unless you catch it), so a cycle can't sneak in.
`Promise.all([rig.run("Load A"), rig.run("Load B")])` runs two *different*
buttons concurrently.

Only one sequence runs at a time, and a button simply won't start — it stays
disabled, with the reason on it — when another sequence is running in this tab
**or another browser tab**, when another client holds control of the bench,
when the bench denies remote control, or while the board is in edit mode.

The logs panel keeps the last 500 lines and drops the oldest, so don't
`rig.log` every pass of a soak loop. A clean finish clears the button's status
line after about 4 seconds; an error stays until the next run.

## Failures and Stop

- A failed `send` (bad path, device error) rejects the run immediately — no
  later steps fire. Wrap in `try/catch` if you want to clean up after a
  *failure* (see the Stop caveat below):

  ```js
  try {
    await rig.send("load1.set_current", { value: 10 });
  } catch (err) {
    rig.log(`load failed: ${err.message}`);
    await rig.send("load1.set_load", { enabled: false });
  }
  ```

- **Stop** ends the run at once: it aborts the current `sleep` and every
  later `rig` call throws. It cannot recall a command that already reached
  the rig — the instrument's own protection (OCP/OPP) and the rack watchdog
  stay in charge of the hardware.

  **A `catch`/`finally` cannot de-energize after Stop.** The block still
  runs, but every `rig.send` inside it throws immediately, so cleanup code
  is a nicety for the failure path only — never the thing that makes a
  procedure safe. That is what L0 instrument limits and the rack watchdog
  are for.

Set the source's current limit before energizing anything, and give sensitive
steps settling time.

## Button options

Sequence buttons are **two-step by default**: first press arms, second
confirms, and it disarms again after 3 seconds untouched. Set
`variant: "instant"` to fire on a single click — only for procedures that are
safe to trigger accidentally. There is no separate `confirm` or `destructive`
field; `variant` is the whole story.

`label` sets the button text (and the name `rig.run` matches). `hotkey` binds
a bare key (`"space"`, `"s"`, `"f2"`), which goes through the same arm → confirm
as a click, so an armed button still needs two presses. `"p"` is reserved for
pause-display. Only bare keys bind: a chord like `ctrl+s` is never claimed, and
hotkeys are ignored while you're typing in a field or while a menu or dialog is
open. Binding the same key to two buttons is allowed, and the first one wins —
which is rarely what you meant.

## Not available in scripts

`rig` is the whole supported surface — write a sequence against it and
nothing else. A script is ordinary JavaScript running in the operator's own
browser tab, so it is **not** sandboxed: don't reach for `fetch`, the DOM or
timers, because nothing about them is supported, guaranteed, or meaningful
on a bench. There is no filesystem.

If a procedure needs measurements with limits and a pass/fail verdict,
promote it to an [OpenHTF test](openhtf-authoring-guide.md).
