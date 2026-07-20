# Guppi — how the single-box install works

This is the technical overview of the Guppi single-box install, shipped with
the source in `guppi-src.tar.gz`. Some source comments cite internal decision
documents (`docs/single-pi-architecture.md §N`, `docs/high-rate-telemetry-architecture.md`)
that record *why* choices were made; this document covers the same ground from
the *what* side.

## One box, five processes

Everything runs on one Raspberry Pi (or any Debian box) with zero cloud
dependency and zero accounts. Power it on, browse to it on the LAN, it works
offline forever.

```
┌──────────────────────────── the Guppi box ───────────────────────────┐
│                                                                       │
│  nats-server            broker: TCP 4222 (rack), WS 9222 (browsers)   │
│                         JetStream KV holds retained rig state         │
│                                                                       │
│  guppi hub (:8000)      FastAPI. Ingests telemetry into Postgres      │
│                         (batched COPY), mediates commands, handles     │
│                         pairing, accepts artifact uploads, serves the  │
│                         prebuilt dashboard, sweeps old telemetry.      │
│                                                                       │
│  postgrest (:3010)      the browser's READ API — auto-generated over   │
│                         Postgres; anonymous role is SELECT-only        │
│                                                                       │
│  postgres               the one data path: same engine, schema, and    │
│                         queries as every other Guppi deployment        │
│                                                                       │
│  rack (guppi rack)      device I/O: VISA/SCPI/CAN instruments. Dials   │
│                         OUT to the broker; nothing connects in to it.  │
└───────────────────────────────────────────────────────────────────────┘
         ▲ LAN browsers (read-only view; actions go through the hub)
```

## Identity without logins

"No auth" means no user login — not no identity. Two roles, no credentials to
type:

| Role | Connects as | May |
| --- | --- | --- |
| rig | `rig:{rig_id}` + a secret generated at first boot | **write**, scoped to its own subjects (`telemetry.frames.{rig_id}.>`, `execution.{rig_id}.>`, its KV bucket) |
| browser | static read-only viewer account | **subscribe only** — live frames, test state, KV reads. Cannot publish; cannot write the database |

> **v0 caveat — the NATS half is not enforced yet.** The single-box install
> ships NATS with the anonymous dev config: the rig/browser subject scoping in
> the table above is the intended model and how clients connect *by convention*,
> not something the broker enforces, until local auth-callout key generation
> lands. What **is** enforced today is the database read-only guarantee — the
> browser reads through PostgREST as `web_anon`, which holds `SELECT`-only
> grants and physically cannot write. On a trusted bench LAN (the design
> assumption) this matches the "anyone may view" posture.

Writes reach Postgres only through the hub's ingest worker. Browsers read via
PostgREST, whose anonymous role holds plain `SELECT` grants (no row-level
security — the box is single-tenant, and everyone on the LAN may view).
Anything that *does* something — run a test, set a voltage — is an HTTP `POST`
to the hub, which relays it to the rig over NATS request/reply.

## Rig identity is self-healing

The source of truth for a rig's identity is the rack's pairing file
(`~/.guppi-rack-pairing.json`), not the hub's database row. Delete the row and
the rack simply re-registers with the same `rig_id` on next connect; history is
keyed by `rig_id` and reattaches. Registration is idempotent, and nothing
cascade-deletes from the rigs table into telemetry or executions.

## The data path

- **Live telemetry** is binary frames on NATS — the browser charts subscribe
  directly; the hub independently batches the same frames and `COPY`s them
  into Postgres (~500 rows / 1 s cadence).
- **History** is read straight from Postgres through PostgREST, including a
  server-side min/max rollup function so charts never pull raw sample floods.
- **Artifacts** (waveform captures) are pushed by the rack as raw bytes to a
  capability URL the hub mints per artifact; bytes live on disk under
  `/var/lib/guppi/artifacts`, metadata in Postgres.
- **Retention** is a bounded window (default 7 days, `TELEMETRY_RETENTION_DAYS`):
  the hub deletes older frames hourly, in batches, so the SD card never fills.
  Durable data is what you explicitly record — test executions and artifacts
  are kept.

## Your database is yours

The read-only invariant constrains the *browser*, not you. Direct SQL against
the local Postgres (psql, Grafana, pandas, Jupyter) is a supported feature —
your data, no export ceremony.

## The rack is deployment-agnostic

The rack has no database, no user identity beyond its rig secret, and no idea
whether the broker it dialed is loopback or hosted. VISA scan, instrument
drivers, the test sequencer, frame publishing, and pairing are identical in
every deployment. It is outbound-only by design: no port forwarding, no
inbound firewall rules, ever.

## Modes

The hub runs in exactly one of two personas, selected explicitly by
`GUPPI_BACKEND`:

- `local` — this box: pinned local owner, no login, PostgREST reads,
  filesystem artifacts. What the installer configures.
- `cloud` — the hosted service: real user auth, hosted Postgres, cloud
  storage, and the AI features. None of that code ships in this package.
