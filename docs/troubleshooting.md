# Troubleshooting

## First moves

```
tmux ls                                  # is a hub session running?
tmux attach -t hub                       # look at the live server logs
curl http://localhost:8000/health
systemctl status postgresql              # the one system service
```

`/health` should return `{"status":"ok","mode":"local","postgres":"ok"}`.
When filing a bug, include the release version (`cat /etc/guppi/version`) and
the last screen of `guppi-hub` output.

## Install failed partway

The installer is idempotent — fix the cause and re-run it. Common causes:

- **`PostgreSQL >= 15 required`** — you're on an older Debian/Ubuntu. The
  installer adds the pgdg repo automatically; if that failed, add it manually
  and retry.
- **No network / GitHub unreachable** — the installer downloads release assets
  from github.com; it needs internet *once*, at install time. The bench runs
  offline afterwards.
- **`No public release found`** — you're ahead of us; check the
  [releases page](https://github.com/ezzatisawesome/guppi/releases) exists and
  has assets, or pin one with `GUPPI_REF=v0.1.0`.

## Dashboard doesn't load

- Is `guppi-hub` running? (`tmux ls`; if not: `tmux new -s hub`, then
  `guppi-hub`.) The dashboard only exists while the hub runs — including after
  a reboot.
- Page loads but says API-only / plain 404s: the UI bundle wasn't installed —
  re-run the installer (it fetches `guppi-ui-local.tar.gz` from the release).
- Loads but shows no live data: check the `guppi-hub` terminal for NATS
  errors; the browser connects to port **9222** (WebSocket) on the same host —
  a firewall between you and the Pi must allow 8000, 9222, and 3010.
- Loads in one browser but not another: some browsers silently upgrade
  `http://` to `https://` (the hub doesn't serve TLS) — disable
  "always use secure connections" for this site, and check Shields/VPN/proxy
  extensions.

## Rig doesn't appear

- Is `guppi-rack` actually running on the bench machine, and did it print a
  scan result? Instruments must be visible to it (USB permissions, Ethernet
  segment).
- Separate rack machine: it must reach the hub — `curl http://<hub>:8000/health`
  from the rack box. If you paired against a raw LAN IP and the hub's address
  changed with a DHCP lease, edit `/etc/guppi-rack.env` to the `.local` mDNS
  name and restart `guppi-rack`.
- Claim code entered but "rig offline": the rack keeps retrying — give it ~10 s,
  then check the rack terminal for connection errors.

## Charts stop / data missing

- History older than the retention window (default 7 days) is deleted by
  design; raise `TELEMETRY_RETENTION_DAYS` in `/etc/guppi/hub.env` (then
  restart `guppi-hub` — Ctrl-C and run it again) if your SD card has room.
- Check disk space: `df -h /var/lib/guppi`. A full disk stops ingest.

## Ports in use

Guppi assumes 8000 (hub), 4222/9222 (NATS), 3010 (PostgREST), and Postgres on
its distro default. If something else owns one of these, stop it or ask in an
issue — ports aren't configurable in v0.

## Starting over

```
# stop guppi-hub first (Ctrl-C in its tmux session, or: tmux kill-session -t hub)
curl -fsSL https://raw.githubusercontent.com/ezzatisawesome/guppi/main/install.sh \
  | sudo GUPPI_PURGE_DATA=1 bash -s -- --uninstall
```

then re-run the installer. This deletes all recorded data.
