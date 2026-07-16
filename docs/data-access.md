# Direct data access

The read-only rule constrains the *browser*, not you. The Postgres on the box
is a normal Postgres, and querying it directly is a supported feature — your
data, no export ceremony.

## On the Pi

```
sudo -u guppi psql guppi
```

The tables you care about:

| Table / view | What's in it |
| --- | --- |
| `telemetry` | raw frames within the retention window (`rig_id`, `path`, `t0`, samples) |
| `telemetry_points` | per-sample view over `telemetry` — one row per (time, value) |
| `test_executions` | every test run: status, timestamps, full result document (`result_json`) |
| `artifacts` | captured waveforms: metadata + `storage_path`; bytes live under `/var/lib/guppi/artifacts` |
| `rigs` | paired rigs |

Example — one signal, last hour, as CSV:

```
sudo -u guppi psql guppi -c "\copy (
  SELECT t, value FROM telemetry_points
  WHERE path = 'psu1.1.volt' AND t > now() - interval '1 hour'
  ORDER BY t
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
    "?path=eq.psu1.1.volt&order=t.desc&limit=10000"
)
```

Waveform artifacts are canonical little-endian float32 — read a capture with
`numpy.fromfile(path, dtype="<f4")` using the `storage_path` from the
`artifacts` row.

## One rule

Treat direct access as **read-only**. The hub owns writes; inserting or
mutating rows underneath it can confuse ingest and the UI. (Deleting old data
is fine — that's what the retention sweeper does.)
