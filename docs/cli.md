# CLI reference

One `guppi` command everywhere. The bench installers build it for you; on any
other machine, install it per [Getting started §5](getting-started.md#5-run-tests-from-your-terminal-optional).

`guppi` on its own shows which hub it talks to, whether you're signed in, and
your rigs, then the commands grouped as below (on a bench box with both the
hub and the rack, it starts the bench instead). `guppi help` lists the
commands; groups have their own help: `guppi keys help`, `guppi skills help`,
`guppi control help`, `guppi rack help`, `guppi rack devices help`,
`guppi rack config help`, `guppi rack deps help`. Any command takes `-h`.

Global options (every command, before or after it): `--hub HUB` (just a
bench's hostname or IP such as `condor` or `192.168.1.40`, `cloud`, `local`,
or a URL), `--token TOKEN` (a login token or an [API key](#agents-and-keys);
default: `GUPPI_TOKEN` / config; not needed on a local bench), and `--json`.

## Connect

```
guppi use [HUB] [--force]                # which bench or hub this CLI talks to
guppi login [--headless] [--code] [--password]  # sign the CLI in to your account
guppi rigs                               # list rigs; with several, pick the default rig
guppi control [cloud|local|URL|allow|deny]   # the rack on this box (run it there)
```

`guppi use condor` points every later command at that bench and saves it in
`~/.guppi/cli.json`. It takes a hostname (`condor`, `condor.local`), an IP,
`host:port`, a URL, `cloud` or `local`. It checks the hub answers before
saving, and tells you whether you need to sign in:

```
$ guppi use condor
✓ Using condor (http://condor.local:8000) — local bench, no login needed
$ guppi use cloud
✓ Using Guppi Cloud — sign in with: guppi login
```

A hub that doesn't answer isn't saved (`--force` saves it anyway). `guppi use`
with no argument shows the hub in use, where that setting came from, and
whether it answers. The order is: `--hub`, then the `GUPPI_HUB` environment
variable, then what `guppi use` saved, then the rack's agent on a rack box,
then `http://localhost:8000`.

If a command can't reach the hub at all, it says so straight away
(`Can't reach condor at http://condor.local:8000 — is its hub running?`)
rather than retrying. Once a command has reached the hub, a dropped connection
is retried, so a long `guppi run` or `guppi migrate` rides out a blip.

`guppi login` — opens your browser; approve there and the terminal is signed
in. The session is handed back over `127.0.0.1`, so a sign-in link someone
else sends you is useless to them even if you approve it.

On a box with no browser, `--headless` prints a URL you can open anywhere and
polls for the approval. That one *is* phishable — approving a stranger's link
hands them your account — so only approve a `--headless` sign-in you started
yourself. `--code` (emailed one-time code) and `--password` are also there.

One sign-in covers everything, `guppi migrate` included. The session is cached
in `~/.guppi/cli.json` and refreshed silently.

`guppi control` is for the rack box. It re-targets that box's rack (and the
CLI on it) to a hub, and says whether that hub may actuate hardware:

```
guppi control              # show who controls this bench and where data goes
guppi control cloud        # hand the rack (and CLI) to Guppi Cloud
guppi control local        # hand them back to the hub on this box
guppi control <url>        # a self-host agent
guppi control deny         # that hub may view, not actuate
guppi control allow        # let it actuate instruments and run tests again
```

Switching repoints the rack's agent (`GUPPI_AGENT_URL` in `~/.guppi/config.env`
— restart the rack to apply) and the CLI's hub (`~/.guppi/cli.json`) together.
The rig keeps its identity across switches; pairings per agent are remembered,
so flipping back needs no re-claim. On a machine with no rack,
`guppi control <hub>` stops and points you at `guppi use <hub>`.

`guppi control deny` makes the bench **view-only** to whatever hub it follows,
even a paired cloud: telemetry, dashboards, data views and history keep
working, but the rack itself refuses instrument commands, test runs and prompt
answers. Stopping always works — abort, safe shutdown and turning an output
off are never refused. It takes effect on the next command, with no restart,
and only someone on the rack box can change it: the hub can't overrule it.
Add `--view-only` to a switch (`guppi control cloud --view-only`) to pair and
deny in one step. `guppi control` with no argument shows the current setting.

## Data

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

For `--bundle`, `EXECUTION` may be a prefix; omit it to take the latest run.
`DIR` defaults to `run-<date>-<id>/`.

### Upload data files

```
guppi upload FILE… [--dry-run] [--rig R] [--device NAME] [--recording [--name NAME]]
                   [--tz ZONE] [--start TIME] [--time-column COL] [--time-format FMT]
                   [--layout wide|long] [--delimiter D] [--decimal .|,] [--skip-rows N]
                   [--unit COL=UNIT]… [--encoding ENC] [--format csv]
guppi uploads [--limit N] [--rig R]
guppi uploads rm <upload id> [--rig R]     # take one back out, to redo it
```

`upload` puts data files (CSV today) into the rig's stored history, on a local
hub or the cloud alike. Each column becomes `<device>.<column>` (the device
defaults to the file name); `--recording` also lists the file as a session on
the timeline. Delimiter,
decimal comma, header, units, layout and the time column and format are
detected — `--dry-run` shows what was picked and writes nothing. Times without
a zone are read in this computer's zone (`--tz` to change); elapsed-time files
need `--start`. The same file twice is one upload. Millions of points are
fine; the CLI shows progress. Details: [Uploading data files](uploading-data.md).

## Run tests

```
guppi run [<test>] [--rig R] [--dut SERIAL] [--step] [--resume-from PHASE] [-y]
guppi abort [--rig R]      # stop the running test
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

`guppi abort` stops the running test; its teardown and `safe_shutdown()` run.

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
the cloud, an org's workspace — the org your rig belongs to (so the team
sees it), or `--org` to pick one; your personal org only when that's unclear.

`push --check` (or `put <file> --check` for one file) checks pages without
uploading anything: the JSON shape and every signal
binding against the rig's catalog, reporting each problem with a JSON pointer
(`/root/children/2/read: unknown signal 'psu1.1.voltagee'`). It exits 1 if
any file has errors. The JSON Schemas for both formats are in `contracts/`
(`dashboard.schema.json`, `data-view.schema.json`) and served by the hub at
`/schemas/dashboard` and `/schemas/data-view`.

## Agents and keys

`guppi keys` makes API keys for coding agents, scripts and apps:

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

Scripts and coding agents:

- `--json` prints one JSON document on stdout; errors print as
  `{"error": ..., "message": ...}` on stderr.
- Nothing prompts without a terminal. A command that would ask fails instead
  and names the flag to pass (`-y`, `--yes`). On a box with no browser, sign in
  with `guppi login --headless`. Give scripts and agents an API key
  (`guppi keys create`) as `GUPPI_TOKEN` — note that keys are refused on
  `guppi migrate`, which needs a signed-in account.
- `guppi run` exits `0` pass, `1` fail, `2` error, `3` aborted.

To set up Claude Code: `guppi skills install` copies five skills into
`~/.claude/skills` — `guppi-pages` (build and edit dashboards and data views as
files), `guppi-analysis` (query history and runs into pandas),
`guppi-rig-setup` (declare a bench and troubleshoot it), `guppi-driver` (write a
driver for an unsupported instrument) and `write-openhtf-test` (write, run and
debug OpenHTF test scripts). They ship with the CLI, so re-run it after
`guppi update`.

## Bench box

These are listed only on a machine with the hub or the rack installed.

```
guppi hub                  # start the hub: NATS + PostgREST + hub, foreground
guppi rack                 # start the rack: scan hardware, pair, stream
```

Both run in the foreground — Ctrl-C stops them. The hyphenated names
`guppi-hub` / `guppi-rack` are the same programs.

```
guppi update               # re-run the installer for whatever this box has;
                           #   data untouched, rollback if the hub fails to start
guppi uninstall [-y]       # remove hub/rack; data kept unless GUPPI_PURGE_DATA=1
```

```
guppi migrate [--since DATE] [--org O] [--dry-run]  # copy local bench history to the cloud
guppi unpair [--yes]                     # un-pair this rig from your account
```

`guppi migrate` — migrates telemetry and runs from the local bench database
to Guppi Cloud. Sign in once with `guppi login` first. Works without pairing
the rig; pairing later adopts the same history. Progress commits per batch,
so Ctrl-C is safe and a re-run resumes where it left off.

The org follows the rig: a rig the cloud already knows imports into its own
org, so a team bench lands where the team can see it. `--org` only applies to
a rig the cloud has never seen (your personal org otherwise). Useful flags:
`--since`, `--batch`, `--org`, `--dry-run`. (`guppi import` still works and
runs `migrate`.)

`guppi unpair` — removes the rig from your account. History is kept; only
the account that paired the rig can unpair it.

### Rig configuration (on the rack box)

```
guppi rack config check    # validate ~/.guppi/rig_config.yml (parse + schema + scan)
guppi rack config check --no-scan   # validate without probing hardware
guppi rack devices         # show devices declared in rig_config.yml
guppi rack devices scan    # print discovered hardware (stable paths), write nothing
```

Adding, editing and switching instruments on or off happens in Guppi itself:
open the rig and choose **Instruments**. It works the same on a bench's own
local site and in the cloud. You can scan for what's plugged in, test an
address before saving, and switch an instrument off without losing its
settings. `rig_config.yml` on the rack stays the source of truth — every change
is written there, comments and all.

See [Configuring your rig](rig-config.md) for the full file reference.
