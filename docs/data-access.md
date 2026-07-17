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
| `telemetry` | raw frames within the retention window (`t0`, `rig_id`, `device_id`, `path`, `unit`, `dt_us[]`, `sample_values[]`) — one row per frame, samples packed into arrays |
| `telemetry_points` | per-sample view that unpacks `telemetry` — one row per sample, with `recorded_at` (timestamp) and `value` |
| `test_executions` | every test run: status, timestamps, full result document (`result_json`) |
| `artifacts` | captured waveforms: metadata + `storage_path`; bytes live under `/var/lib/guppi/artifacts` |
| `rigs` | paired rigs |

Example — one signal, last hour, as CSV:

```
psql -U guppi -h /var/run/postgresql guppi -c "\copy (
  SELECT recorded_at, value FROM telemetry_points
  WHERE path = 'psu1.1.volt' AND recorded_at > now() - interval '1 hour'
  ORDER BY recorded_at
) TO '/tmp/volt.csv' CSV HEADER"
```

## From another machine

Two options:

- **HTTP (no setup):** PostgREST already serves read-only JSON on port 3010 —
  `curl 'http://bench.local:3010/telemetry_points?path=eq.psu1.1.volt&limit=100'`.
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
    "?path=eq.psu1.1.volt&order=recorded_at.desc&limit=10000"
)
```

Waveform artifacts are canonical little-endian float32 — read a capture with
`numpy.fromfile(path, dtype="<f4")` using the `storage_path` from the
`artifacts` row.

## One rule

Treat direct access as **read-only**. The hub owns writes; inserting or
mutating rows underneath it can confuse ingest and the UI. (Deleting old data
is fine — that's what the retention sweeper does.)
