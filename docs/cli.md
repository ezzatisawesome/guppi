# CLI reference

One `guppi` command everywhere. The bench installers build it for you; on any
other machine, install it per [Getting started §5](getting-started.md#5-run-tests-from-your-terminal-optional).

Global options (every command, before or after it): `--hub URL` (default:
`GUPPI_HUB` env var, then config, then `http://localhost:8000`), `--token TOKEN`
(a login token or an [API key](#account-and-cloud); default: `GUPPI_TOKEN` /
config; not needed on a local bench), and `--json`.

`guppi help` lists every command. Groups have their own: `guppi keys help`,
`guppi control help`, `guppi rack help`, `guppi rack devices help`,
`guppi rack config help`, `guppi rack deps help`. Any command takes `-h`.

## Scripts and coding agents

- `--json` prints one JSON document on stdout; errors print as
  `{"error": ..., "message": ...}` on stderr.
- Nothing prompts without a terminal. A command that would ask fails instead
  and names the flag to pass (`-y`, `--yes`). `guppi login` needs a terminal;
  give scripts and agents an API key (`guppi keys create`) as `GUPPI_TOKEN`.
- `guppi run` exits `0` pass, `1` fail, `2` error, `3` aborted.

To set up Claude Code: `guppi skills install` copies two skills into
`~/.claude/skills` — `guppi-pages` (build and edit dashboards and data views as
files) and `guppi-analysis` (query history and runs into pandas). They ship
with the CLI, so re-run it after `guppi update`.

## Reading a rig

```
guppi catalog [filter] [--kind signal|capability] [--values] [--rig R]
guppi query <path…> [--since 1h] [--until now] [--buckets 2000|raw] [--format json|csv] [--rig R]
guppi runs [EXECUTION] [--bundle [DIR]] [--limit N] [--rig R]
```

- `catalog` — every signal and command the rig exposes, with its real path.
  Use these paths in dashboards, sequences and queries. `--values` adds each
  signal's current value, read live from the rig (narrow it with a filter:
  `guppi catalog psu1 --values`).
- `query` — stored history. Times are ISO 8601, `now`, or a span ago
  (`15m`, `2h`, `3d`). Rolled-up rows carry `v_min`/`v_max`, so a short spike
  survives a long window; `--buckets raw` returns raw samples (capped at
  100k). `--format csv` is ready for pandas:
  `guppi query psu1.1.voltage psu1.1.current --since 12h --format csv > soak.csv`.
- `runs` — test runs, newest first; with an id, one run in full, including
  its measurements and time window; `--bundle [DIR]` writes that run's
  `run.json`, `measurements.csv` and captured waveforms (`scope/`) to a folder.

## Dashboards and data views as files

```
guppi ls [prefix]           guppi cat <path>
guppi put <local|-> [path]  guppi rm <path>
guppi pull [dir]            guppi push [dir] [--check]
```

Dashboards (`dashboards/*.json`) and data views (`data-views/*.json`) are
files, so you or a coding agent can edit them like any other file: `pull`
into a folder, change them, `push` back. `push` uploads only files that
differ, and first checks every changed page's shape: if any fails, nothing
is uploaded (`--no-validate` overrides). A page that's open in the app reloads within a few seconds of a
push; if it has unsaved edits there, the app asks whether to keep them or
load the new version. On a local
bench these are the rig's workspace (`pull`/`push` also sync `tests/`); in
the cloud, an org's workspace — your personal org unless you pass `--org`.

`push --check` (or `put <file> --check` for one file) checks pages without
uploading anything: the JSON shape and every signal
binding against the rig's catalog, reporting each problem with a JSON pointer
(`/root/children/2/read: unknown signal 'psu1.1.voltagee'`). It exits 1 if
any file has errors. The JSON Schemas for both formats are in `contracts/`
(`dashboard.schema.json`, `data-view.schema.json`) and served by the hub at
`/schemas/dashboard` and `/schemas/data-view`.

## Running tests

```
guppi run [<test>] [--rig R] [--dut SERIAL] [--step] [--resume-from PHASE] [-y]
```

`<test>` is a saved test name (`tests/<slug>.py` in the rig workspace) or a
path to a `.py` file — relative, `~`, or absolute (single-box benches, where
the CLI and rig share a disk). The script's own directory is importable, so a
test living in your firmware repo can import sibling modules and read data
files next to it. Omit it to pick from the rig's saved tests (arrow-key
menu, `1-9` jump). The CLI derives the plan, shows it, asks for approval,
then runs — any `prompt()` in the script is answered inline in your terminal.

- `--rig R` — which rig to run on (default: `GUPPI_RIG`, or the only paired rig).
- `--dut SERIAL` — record the DUT serial on the execution.
- `--step` — pause for confirmation before every phase (debug overlay; the
  gates never appear in the plan or results).
- `--resume-from PHASE` — re-run a finished run from this phase onward
  (see [Writing tests §8](openhtf-authoring-guide.md#8-sweeps-and-resume)).
- `-y` / `--yes` — skip the plan-approval prompt (unattended runs).

## Results

```
guppi runs [EXECUTION] --bundle [DIR]
```

Writes a run bundle — `run.json`, `measurements.csv`, and captured waveforms
under `scope/`. `EXECUTION` is an execution id (a prefix is enough); omit it
to take the latest run. `DIR` defaults to `run-<date>-<id>/`.

## Bench control

```
guppi abort [--rig R]      # stop the running test
guppi rigs                 # list rigs; with several, pick the default rig
guppi control              # show who controls this bench and where data goes
guppi control cloud        # hand the rack (and CLI) to Guppi Cloud
guppi control local        # hand them back to the hub on this box
guppi control <url>        # a self-host agent
guppi control deny         # that hub may view, not actuate (run on the rack box)
guppi control allow        # let it actuate instruments and run tests again
```

`guppi control` is the one switch for "local island or cloud": it repoints the
rack's agent (`GUPPI_AGENT_URL` in `~/.guppi/config.env` — restart the rack to
apply) and the CLI's hub (`~/.guppi/cli.json`) together. The rig keeps its
identity across switches; pairings per agent are remembered, so flipping back
needs no re-claim.

`guppi control deny` makes the bench **view-only** to whatever hub it follows,
even a paired cloud: telemetry, dashboards, data views and history keep
working, but the rack itself refuses instrument commands, test runs and prompt
answers. Stopping always works — abort, safe shutdown and turning an output
off are never refused. It takes effect on the next command, with no restart,
and only someone on the rack box can change it: the hub can't overrule it.
Add `--view-only` to a switch (`guppi control cloud --view-only`) to pair and
deny in one step. `guppi control` with no argument shows the current setting.

## Account and cloud

```
guppi login [--email E] [--password]     # sign the CLI in to the hub
guppi migrate [--since DATE] [--dry-run] # copy local bench history to the cloud
guppi unpair [--yes]                     # un-pair this rig from your account
```

- `guppi login` — magic-link by default (check your email, then paste the
  6-digit code or the link back into the terminal). Add `--password` to be
  prompted for a password instead. The token is cached in `~/.guppi/cli.json`.
- `guppi migrate` — migrates telemetry and runs from the local bench database
  to Guppi Cloud. Works without pairing the rig first; pairing later adopts
  the same history. Progress commits per batch, so Ctrl-C is safe and a
  re-run resumes where it left off. Useful flags: `--since`, `--batch`,
  `--dry-run`. (`guppi import` still works and runs `migrate`.)
- `guppi keys` — API keys for coding agents, scripts and apps:

  ```
  guppi keys create --name claude-code --scope read,write [--rig R | --org O]
  guppi keys ls
  guppi keys revoke <id>
  ```

  A key acts as your account, limited to its scopes: `read` (catalog, signals,
  history, runs, workspace files) and `write` (create, change and delete
  dashboards and data views, nothing else in the workspace). Keys can't run
  tests, write test scripts, send instrument commands, manage keys, or reach
  account and org administration. A key pinned to a rig or org stays there. The token prints once; use it as
  `GUPPI_TOKEN` or `--token`. Keys work on a local bench too, where they keep
  their limits even though the bench itself needs no login.
- `guppi unpair` — removes the rig from your account. History is kept; only
  the account that paired the rig can unpair it.

## Rig configuration (on the rack box)

```
guppi rack config check    # validate ~/.guppi/rig_config.yml (parse + schema + scan)
guppi rack config check --no-scan   # validate without probing hardware
guppi rack devices         # full-screen app: see, add, edit and test every device
guppi rack devices add     # the same app, opened straight on its Add screen
guppi rack devices list    # show devices declared in rig_config.yml
guppi rack devices scan    # print discovered hardware (stable paths), write nothing
```

`guppi rack devices` with no subcommand is the one to reach for: it runs over
SSH on the rack box, lists every device with a reachability dot, adds from a
bus scan, edits any parameter in place, and connects to the instrument to show
you a real reading before anything is written. The YAML — comments and all —
stays the source of truth underneath. With no terminal to draw on (piped, cron,
CI) it prints the device list and exits instead of hanging; `devices add`
exits with an error, since there is nothing to add from without a screen —
edit `rig_config.yml` and run `guppi rack config check` instead.

It is driven entirely from the keyboard; there are no buttons to click:

| key | |
|---|---|
| `a` | add a device (scans VISA, the network and the serial ports) |
| `e` / `enter` | edit the selected device |
| `space` | enable / disable it |
| `d` | remove it |
| `r` | re-probe reachability |
| `D` | drivers & dependencies — add a driver path, install an extra |
| `q` | quit |

On a device form: `^s` saves, `^t` connects and reads the instrument, `esc`
goes back. In a channel tick-list, `space` toggles the channel under the
cursor, `a` takes all and `n` takes none. A parameter you have changed away
from its default is marked with what the default was; a folded "more settings"
section says how many of its rows you have set.

**Stop the rack before scanning or testing** — a running rack holds the
instruments, and the app says so on a banner rather than refusing to open.
Viewing and editing the config work either way.

See [Configuring your rig](rig-config.md) for the full file reference.

## Servers (on the bench boxes)

```
guppi hub                  # start the hub: NATS + PostgREST + hub, foreground
guppi rack                 # start the rack: scan hardware, pair, stream
```

Both run in the foreground — Ctrl-C stops them. The hyphenated names
`guppi-hub` / `guppi-rack` are the same programs.

## Maintenance (on the bench boxes)

```
guppi update               # re-run the installer for whatever this box has;
                           #   data untouched, rollback if the hub fails to start
guppi uninstall [-y]       # remove hub/rack; data kept unless GUPPI_PURGE_DATA=1
```
