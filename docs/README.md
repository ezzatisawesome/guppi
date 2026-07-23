# Guppi documentation

Everything you need to run a bench with Guppi, in the order you'll want it.

## 1. Install it
[**Getting started**](getting-started.md) — blank SD card → live telemetry:
install the hub (`curl … | sudo bash`), connect your instruments with
`guppi rack`, and open the dashboard at `http://<host>.local:8000`. Also covers
upgrading (`guppi update`) and pinning a version.

## 2. Use & interact with it
- [**Getting started — Use it**](getting-started.md#4-use-it) — the live
  dashboard, the data viewer, and running tests.
- [**Run tests from your terminal**](getting-started.md#5-run-tests-from-your-terminal-optional)
  — the `guppi` CLI: `guppi rigs`, `guppi run <test>`, `guppi results`,
  `guppi abort`.
- [**Writing tests**](openhtf-authoring-guide.md) — authoring OpenHTF test
  scripts to Guppi standards: the `TEST_PHASES` contract, measurements and
  limits, prompts, the three safety layers, declarative sweeps, and capturing
  waveforms/sweep metrics by reference.
- [**Direct data access**](data-access.md) — your data is a normal Postgres:
  query it with `psql`, PostgREST (HTTP/JSON), pandas, or Grafana. No export
  ceremony.
- [**Configuring your rig**](rig-config.md) — the full `rig_config.yml`
  reference: device layout, networked-instrument discovery, and L1 safety
  abort-limits. Validate with `guppi rack config check`.

## 3. Create a driver
[**Instrument drivers**](drivers.md) — 200+ instruments already ship. When
yours isn't covered, write one Python class: pick a family base (`Device`,
`ScpiInstrument`, `ChannelInstrument`, `ScpiScope`, `SweptAnalyzer`), scaffold
it with `make new-driver`, and drop it in via `rig_config.yml`.

## When something's wrong
[**Troubleshooting**](troubleshooting.md) — services, logs, and the common
failures.

## Under the hood
[**Architecture**](architecture.md) — how the single-box install fits together
(hub, rack, NATS, Postgres).
