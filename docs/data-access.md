# Direct data access

The read-only rule constrains the *browser*, not you. The Postgres on the box
is a normal Postgres, and querying it directly is a supported feature — your
data, no export ceremony.

## On the Pi

```
psql -U guppi -h /var/run/postgresql guppi
```

The installer trusts the local `guppi` role on the Unix socket, so no password
is needed. (There's no `guppi` OS user — the hub runs as whoever installed it.)

The tables you care about:

| Table / view | What's in it |
| --- | --- |
| `telemetry_points` | **start here** — one row per sample: `recorded_at` (timestamp), `value`, `path` (e.g. `psu1.1.voltage`), `unit`, `rig_id` (plus `device_id`, `text_value` for string signals, and a few more) |
| `telemetry` | the compact frame storage behind that view — one row per frame with samples packed into arrays, addressed by `channel_id`. Query `telemetry_points` unless you know you want frames |
| `telemetry_channels` | one row per signal: `channel_id` ↔ `rig_id` + `device_id` + `path` + `unit` |
| `test_executions` | every test run: status, timestamps, full result document (`result_json`) |
| `artifacts` | captured waveforms: metadata + `storage_path`; bytes live under `/var/lib/guppi/artifacts` |
| `rigs` | paired rigs |

`telemetry` / `telemetry_points` are the **real samples** — every admitted
sample, exactly as recorded. You may also notice `telemetry_rollup_*` tables:
those are pre-computed min/max/mean summaries the charts use to stay fast at
wide zooms. For analysis, query the raw tables — never the rollups — so
nothing you read was averaged or decimated.

Example — one signal, last hour, as CSV:

```
psql -U guppi -h /var/run/postgresql guppi -c "\copy (
  SELECT recorded_at, value FROM telemetry_points
  WHERE path = 'psu1.1.voltage' AND recorded_at > now() - interval '1 hour'
  ORDER BY recorded_at
) TO '/tmp/volt.csv' CSV HEADER"
```

## From another machine

Two options:

- **HTTP (no setup):** PostgREST already serves read-only JSON on port 3010 —
  `curl 'http://bench.local:3010/telemetry_points?path=eq.psu1.1.voltage&limit=100'`.
  Handy for scripts and notebooks; capped at 10 000 rows per request.
- **SQL (opt-in):** Postgres listens only on the local socket by default.
  To open it to your LAN, edit `postgresql.conf` (`listen_addresses`) and
  `pg_hba.conf` yourself — standard Postgres administration, at your own
  discretion on your own network.

## Notebooks / Grafana

Anything that speaks Postgres or HTTP works. pandas via PostgREST:

```python
import pandas as pd
df = pd.read_json(
    "http://bench.local:3010/telemetry_points"
    "?path=eq.psu1.1.voltage&order=recorded_at.desc&limit=10000"
)
```

Waveform artifacts are canonical little-endian float32 — read a capture with
`numpy.fromfile(path, dtype="<f4")` using the `storage_path` from the
`artifacts` row.

## One rule

Treat direct access as **read-only**. The hub owns writes; inserting or
mutating rows underneath it can confuse ingest and the UI. (Deleting old
telemetry rows is fine — there's no automatic sweeper, so this is how you
reclaim space; the Storage tab does the same thing through the UI.)
