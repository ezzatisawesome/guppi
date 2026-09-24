# Dashboards & data views

Two kinds of live document, both plain JSON files in your rig workspace:

- **Dashboards** (`dashboards/*.json`) — live monitoring and control: readouts,
  plots, toggles, buttons, P&ID diagrams.
- **Data views** (`data-views/*.json`) — timeline analysis: signal history on a
  shared clock with runs, sessions, and markers painted on top.

Both can live in any folder — they're recognized by their content, addressed
by path. You can build them by hand in the editor, or just describe what you
want to the Guppi agent — it builds and edits boards for you, and your manual
edits survive its updates.

## Building a dashboard

Create one from the workspace (**+ New Dashboard**), then hit **Edit** in the
toolbar. Drag blocks from the palette onto the canvas, drag to move, drag
edges to resize. ⌘Z / ⌘⇧Z undo and redo; ⌘S (or **Done**) saves.

A dashboard is a tree: containers arrange, leaves bind one signal each.

**Containers** — `canvas` (grid-placed blocks, pannable), `panel` (titled box),
`stack` / `row` / `grid` (vertical / horizontal / multi-column flow), `tabs`,
`section` (collapsible), `table` (test-result matrix).

**Leaves** bind a signal with `read` (and `write` for controls) and style
themselves from the signal's metadata — unit, min/max, analog vs digital:

| Group | Types |
|---|---|
| Readouts | `readout` (value + sparkline), `sparkline`, `waveform` (big plot), `stat`, `bar`, `progress`, `gauge` |
| Digital | `status_dot`, `led_bank`, `annunciator` (alarm tiles) |
| Controls | `toggle`, `button`, `setpoint`, `slider`, `dial`, `select`, `text_input` |
| Scripts | `sequence` — a scripted multi-step button ([Buttons & sequences](sequences.md)) |
| Media | `trace` (scope waveforms), `media` (camera stream / latest capture / URL), `xy_plot` (I-V curves), `orientation` (3D attitude), `matrix` |
| Annotations | `note`, `label` |

Example — a PSU panel:

```json
{ "type": "panel", "title": "PSU1", "children": [
  { "type": "readout",  "read": "psu1.voltage", "label": "Voltage" },
  { "type": "readout",  "read": "psu1.current", "label": "Current" },
  { "type": "setpoint", "read": "psu1.voltage", "write": "psu1.set_voltage", "label": "Set V" }
]}
```

## Signals and formulas

Signals are dot-paths through the rig catalog: `psu1.voltage`,
`eload1.1.current` (device, channel, signal). Anywhere a path binds a value
you can write a **formula** instead:

```
eload1.1.voltage * eload1.1.current        # power
(tc1.temp - 32) / 1.8                      # unit conversion
pressure > 300                             # 1 or 0 — good for alarms
```

Operators `+ - * / % ^` and comparisons, plus the usual math functions
(`sqrt`, `abs`, `min`, `max`, `log`, trig, …) and constants `pi`, `e`.

## P&ID diagrams

Draw your plumbing on the same canvas. Drop ISA symbols — `tank`, `pump`,
`valve` (plus ball/check/3-way/relief), `mfc`, `filter`, `heat_exchanger`,
`instrument` (the PI/TI/FI bubble, bind `read` and set `tag`) — then arm pipe
mode and click two symbols to connect them. Connectors can be `pipe` or
`wire`, route through corner waypoints (drag a segment to bend it), and change color
live with rules evaluated top-to-bottom:

```json
{ "type": "connector", "sourceId": "pump-1", "targetId": "tank-1",
  "edgeKind": "pipe",
  "colorRules": [
    { "when": "flow > 400", "color": "#ef4444", "pulse": true },
    { "when": "flow > 0",   "color": "#22c55e" }
  ]}
```

The `when` clauses are ordinary signal formulas; first match wins.

## Live data, recording, pause

Widgets update as each new telemetry frame arrives — the pace is set by the
rig's sampling rate (default once a second). Two switches to know:

- **Start recording** (toolbar, or `rig.telemetry(true)` from a sequence) —
  saves telemetry to history. Live view works either way.
- **Pause display** (`P`) — freezes the screen while data keeps flowing and
  recording continues; resume snaps back to live.

## Data views

A data view is a stack of **lanes**, each a strip of time with one or more
blocks (plots, stats, scope traces, images, logs) reading the signals you
list. Lanes have their own time window or link to a shared one so they pan
and zoom together; a live window rides "now" until you pan, and snaps back
when you resume.

On top of the curves, the view paints what happened: test **runs** (pass/fail
bands — click one to focus its time range), recording **sessions**, rig
**offline** spans, instrument **connect/disconnect** events, **captures**
(scope shots as point-in-time markers), and notes from `rig.annotate()`. Add
your own **markers** with Alt+click; Alt+drag spans a region.

When you type a formula in a plot legend, matching signal names are suggested
as you type — pick one and the full signal reference is inserted; you never
hand-type a rig id.

Plots autoscale as data flows; drag to pan, scroll to zoom, Shift+scroll to
pan in time.

## What a chart shows — and what it doesn't

Zoomed out, a chart cannot draw every sample, so it draws summarized buckets.
Know exactly what that means so you never mistake a summary for the data:

- **The line is the bucket mean; the shaded band around it is the true
  min–max** of every sample in that bucket. The extremes are exact, never
  re-sampled away — a one-sample spike gets visually narrow at wide zooms,
  but its full height stays in the band. If the band is wide, there's
  structure inside the bucket: zoom in.
- **Zooming in switches to real samples.** Charts always use the finest
  detail available for the window; narrow the window enough and you are
  looking at the raw stream, not a summary. The live tail is always raw.
- **Scope captures are never decimated in storage.** The on-screen thumbnail
  is a spike-preserving min/max envelope, but the artifact holds every
  sample.
- **Read numbers from data, not from pixels.** For analysis, limits, or
  anything that matters, pull the real samples: `guppi results` exports a
  run's measurements and full waveforms to CSV, and the whole history is
  plain SQL away — see [Direct data access](data-access.md).

## Working with the agent

The agent sees the board you have open. Ask it to "add a lane with pack
voltage and current", "wire the P&ID so the feed line turns red over 400 kPa",
or "write a power-on sequence button" — it edits the JSON through patch
operations, so it changes only what you asked and leaves the rest of your
layout alone.
