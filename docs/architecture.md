# Guppi — how the single-box install works

What's actually running on your bench box, and the guarantees you can rely on.

## One box, five processes

Everything runs on one Raspberry Pi (or any Debian box) with zero cloud
dependency and zero accounts. Power it on, browse to it on the LAN, it works
offline forever.

```
┌──────────────────────────── the Guppi box ───────────────────────────┐
│                                                                       │
│  message broker         live telemetry: TCP 4222 (rack),              │
│                         WebSocket 9222 (browsers)                     │
│                                                                       │
│  guppi hub (:8000)      the app: serves the dashboard, stores         │
│                         telemetry, mediates commands and pairing      │
│                                                                       │
│  read API (:3010)       how browsers read history from the database   │
│                                                                       │
│  postgres               your data — a normal Postgres you can query   │
│                                                                       │
│  rack (guppi rack)      device I/O: VISA/SCPI/CAN instruments. Dials  │
│                         OUT to the hub box; nothing connects in.      │
└───────────────────────────────────────────────────────────────────────┘
         ▲ LAN browsers (read-only view; actions go through the hub)
```

## What that means for you

- **No logins on the bench.** Anyone on the LAN can view; anything that
  *changes state* — running a test, setting a voltage — goes through the hub. The design
  assumption is a trusted bench LAN.
- **Browsers can't write.** The dashboard reads history through a role that
  physically cannot modify the database.
- **The rack is outbound-only.** No port forwarding, no inbound firewall
  rules, ever — it dials out to the hub, whether that hub is on the same box
  or in the cloud.
- **Rig identity survives reinstalls.** The rig's identity lives in
  `~/.guppi/identity.json` on the rack box. Reinstall the hub or delete the
  rig row and the rack re-registers with the same id; history is keyed by that
  id and reattaches.

## The data path

- **Live telemetry** streams straight to your browser charts; the hub stores
  the same stream into Postgres in the background.
- **History** is read from Postgres, with server-side rollups so charts stay
  fast over wide time windows.
- **Artifacts** (waveform captures, screenshots) live on disk under
  `/var/lib/guppi/artifacts`, with metadata in Postgres.
- **Retention**: telemetry is kept **indefinitely** — there is no automatic
  time-based sweeper. Reclaim space by pruning specific channels from the
  Storage tab (a hard delete). Test executions and artifacts are always kept.

## Your database is yours

The read-only rule constrains the *browser*, not you. Direct SQL against the
local Postgres (psql, Grafana, pandas, Jupyter) is a supported feature — see
[Direct data access](data-access.md). Your data, no export ceremony.

## Local island or cloud

The same box can run as a local island (no accounts, what the installer sets
up) or hand control to Guppi Cloud for remote access, team sharing, and the AI
features. `guppi control cloud` / `guppi control local` is the one switch —
the rig keeps its identity and history across the move. See the
[CLI reference](cli.md#bench-control).
