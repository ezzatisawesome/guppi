# CLI reference

One `guppi` command everywhere. The bench installers build it for you; on any
other machine, install it per [Getting started §5](getting-started.md#5-run-tests-from-your-terminal-optional).

Global options (every command): `--hub URL` (default: `GUPPI_HUB` env var, then
config, then `http://localhost:8000`) and `--token TOKEN` (default:
`GUPPI_TOKEN` / config; not needed on a local bench).

## Running tests

```
guppi run [<test>] [--rig R] [--dut SERIAL] [--step] [--resume-from PHASE] [-y]
```

`<test>` is a saved test name (`tests/<slug>.py` in the rig workspace) or a
path to a `.py` file. Omit it to pick from the rig's saved tests (arrow-key
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
guppi results [EXECUTION] [--rig R] [-o DIR]
```

Writes a run bundle — `run.json`, `measurements.csv`, and captured waveforms
under `scope/`. `EXECUTION` is an execution id (a prefix is enough); omit it
to pick from the recent runs (on a terminal — piped use takes the latest).
`-o DIR` sets the output directory (default: `run-<date>-<id>/`).

## Bench control

```
guppi abort [--rig R]      # stop the running test
guppi rigs                 # list rigs; with several, pick the default rig
guppi control              # show who controls this bench and where data goes
guppi control cloud        # hand the rack (and CLI) to Guppi Cloud
guppi control local        # hand them back to the hub on this box
guppi control <url>        # a self-host agent
```

`guppi control` is the one switch for "local island or cloud": it repoints the
rack's agent (`GUPPI_AGENT_URL` in `~/.guppi/config.env` — restart the rack to
apply) and the CLI's hub (`~/.guppi/cli.json`) together. The rig keeps its
identity across switches; pairings per agent are remembered, so flipping back
needs no re-claim.

## Rig configuration (on the rack box)

```
guppi rack config check    # validate ~/.guppi/rig_config.yml (parse + schema + scan)
guppi rack config check --no-scan   # validate without probing hardware
guppi rack devices add     # guided wizard: add an instrument to the config
guppi rack devices list    # show devices declared in rig_config.yml
guppi rack devices scan    # print discovered hardware (stable paths), write nothing
```

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
