# Dashboards & data views

Two kinds of live document, both plain JSON files in your rig workspace:

- **Dashboards** (`dashboards/*.json`) — live monitoring and control: readouts,
  plots, toggles, buttons, P&ID diagrams.
- **Data views** (`data-views/*.json`) — timeline analysis: signal history on a
  shared clock with runs, sessions, and markers painted on top.

Keep them in those two folders: the folder is what makes a file a dashboard
or a data view, and the page lists only look there. Build them by hand in the
editor, or have a coding agent write them (see
[Building with a coding agent](#building-with-a-coding-agent)).

## Building a dashboard

Create one from the workspace (**+ New Dashboard**), then hit **Edit** in the
toolbar. Drag blocks from the palette onto the canvas, drag to move, drag
edges to resize. ⌘Z / ⌘⇧Z undo and redo; ⌘S (or **Done**) saves.

**Selecting several blocks.** Shift-click adds a block (or a P&ID pipe) to the
selection, or takes it out. Shift-drag on empty board draws a box: it picks
every block it touches, and inside a P&ID panel, the symbols it fully encloses.
⌘A selects everything; Esc or a plain click goes back to one block. Drag any
selected block to move the whole selection.

**Copy and paste.** ⌘C / ⌘X / ⌘V / ⌘D and Delete act on the whole selection.
The copy goes through the system clipboard, so it pastes into another
dashboard or another tab. Pasted blocks keep their layout and their signal
bindings, and pipes come along when both ends were copied. With nothing
selected, a paste lands in view; with a block selected, it lands beside it,
or inside it if it's a panel.

A dashboard is a tree: containers arrange, leaves bind one signal each.

**Containers** — `canvas` (grid-placed blocks, pannable), `panel` (titled box;
`fill` sets its background, and a dark one makes an instrument face), `stack` / `row` / `grid` (vertical / horizontal / multi-column flow),
`tabs`, `table` (channel rows).

**Leaves** bind a signal with `read` (and `write` for controls) and style
themselves from the signal's metadata — unit, min/max, analog vs digital:

| Group | Types |
|---|---|
| Values | `readout` (`size` sm / md / lg for a big number, `trend: true` for a sparkline), `bar` (`percent`, `variant: "vertical"`), `waveform` (big plot) |
| Digital | `indicator` — `style` dot (LEDs), tile (alarm tiles) or chip (status tags) |
| Controls | `toggle`, `button` (give it a `script` for a multi-step button — [Buttons & sequences](sequences.md)), `setpoint` (`variant` stepper / slider / fader / dial), `select` |
| Media | `media` (camera stream / latest capture / URL), `xy_plot` (I-V curves) |
| Text | `label` (a banner, or `variant: "note"` for markdown) |
| More | `trace` (scope waveforms), `matrix`, `orientation` (3D attitude), `text_input` |

`readout` and `bar` take limits: outside `warnMin`/`warnMax` the value turns
amber, outside `limitMin`/`limitMax` red.

Older boards that use retired names (`stat`, `sparkline`, `gauge`, `progress`,
`status_dot`, `led_bank`, `annunciator`, `slider`, `dial`, `note`, `sequence`,
`section`, `image`) still open — they're converted on load and saved in the new
form.

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
`instrument` (the PI/TI/FI bubble, bind `read` and set `tag`). For electrical
schematics there are `switch`, `relay`, `breaker`, `fuse`, `psu`, `eload`,
`battery`, `meter`, `motor` and `ground` — wire them with `wire` connectors
(or `bus` for a heavy rail). Then arm pipe
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
  saves telemetry to history. Live view works either way. Every recording has
  a name — the one you type, else its start time ("Recording 14:02"). If the
  rig goes off mid-recording, the recording stays open and saving picks up when
  it's back; **Stop** works with the rig off too, ending the recording when you
  press it.
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

Rig offline spans are recorded by the hub as they happen, from the rig's last
heartbeat to its first one back, so they're there after a reload, on another
machine, and for stretches nobody had the page open.

### Runs

The **Runs** panel lists every test run and recording, newest first. Search
it, filter by result, and group it by name, serial, rig or tag. Click a run to
open it in this view: every lane moves to the run's window, and the link
(`?run=`) opens the same run for anyone you send it to. Click the run again to
leave it; each lane goes back where it was.

- **Tags** — label any run (`DUT-7`, `thermal-campaign`); a run can have
  several. Grouping by tag lists a run under each of its tags.
- **Rename a recording, or change its times** — from its row (pencil, clock).
  A rename shows everywhere, for everyone. Recordings made before this release
  are renamed per view until they're brought into the hub's records.
- **Change a test run's times** — open its log and use *edit times*. The times
  the rig recorded are kept; *reset to recorded* puts them back. No data is
  deleted either way: a run is a window over the history.
- **Delete** removes the run, its log and its captures, and it stays deleted —
  a re-run `guppi migrate` or a replayed rig event won't bring it back.

#### Share a view by link

Click **share** on the view's toolbar and turn on **Anyone with the link**. The
link is copied, and it shows what's on screen right now to anyone, no sign-in:
this view's layout with each lane on the time window it shows. They can zoom
and pan inside that time frame, read-only. A lane following live is frozen
when you open the share panel.

- Turning the switch off stops that link; turning it back on for the same
  screen brings back the same link.
- Pan or change the view and share again for a new link. Links you already
  sent keep showing what they showed.
- When other links to the view are on, the panel says how many, with **Turn
  all off**.

A shared link reads only what it shows: the view's plots, stats, string and
digital channels, inside its time frame. Traces, images and logs aren't
included, and a rig drops out of the link if the person who shared it loses
access to it.

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
  anything that matters, pull the real samples: `guppi runs <id> --bundle` exports a
  run's measurements and full waveforms to CSV, and the whole history is
  plain SQL away — see [Direct data access](data-access.md).

## Building with a coding agent

Dashboards and data views are files, so Claude Code (or any coding agent with
a shell) can build them for you. Run `guppi skills install` once; then ask it
to "add a lane with pack voltage and current", "wire the P&ID so the feed line
turns red over 400 kPa", or "write a power-on sequence button". It looks up
the real signal paths (`guppi catalog`), edits the JSON, checks it against the
rig (`guppi push --check`) and pushes it (`guppi push`). A page you have open
reloads within a few seconds; if you have unsaved edits on it, the app asks
which to keep. See [Dashboards and data views as files](cli.md#dashboards-and-data-views-as-files).
