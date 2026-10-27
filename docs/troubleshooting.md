# Troubleshooting

## First moves

```
curl http://localhost:8000/health        # is the hub answering?
systemctl status postgresql              # the one system service
```

If the hub isn't answering, look at the terminal you started `guppi hub` in —
that's where all the server logs are (Guppi runs in the foreground, not as a
background service).

`/health` should return `{"status":"ok","mode":"local","postgres":"ok"}`.
When filing a bug, include the release version (`cat /etc/guppi/version`) and
the last screen of `guppi hub` output.

## The rack's log

The rack keeps a durable log at **`~/.guppi/logs/rack.log`** (5 MB, 3 rotations;
override with `GUPPI_LOG_FILE`). The terminal stays quiet on purpose — it shows
the self-check and pairing lines, not the play-by-play — so this file is where
the narrative lives: links opening, devices identifying, instruments dropping
out and coming back.

Every line is stamped in **UTC, to the millisecond**, on the same clock as
telemetry samples. So a gap in a chart can be looked up directly:

```
tail -f ~/.guppi/logs/rack.log
grep 'quarantined' ~/.guppi/logs/rack.log       # when did instruments drop out?
awk '$1 > "2026-10-08T14:30:00"' ~/.guppi/logs/rack.log
```

Note the times on a dashboard or data view are shown in your browser's local
zone, while the log is UTC — convert before comparing.

An instrument that goes dark is reported **once**, not once per reading, and
once more when it comes back. If you want the full play-by-play (every SCPI
exchange), run `guppi rack --verbose`; that goes to the terminal, not the file,
because at a real poll rate it is gigabytes a day.

Repetition is bounded for **every** logger, including a driver you wrote
yourself: the first occurrence is logged in full, repeats inside a minute are
dropped, and the next one through carries how many were suppressed —

```
... TMC4671 poll failed: no data [+412 more in the last 60s]
```

"The same message" means the same logger, level, and wording, with the same
*identifying* values — a device id, address or command. Measurements don't
count, so `psu1` at 24.5 Hz and then 25.1 Hz is one line, while `psu1` and
`psu2` are always two. Suppression tracks the last 512 distinct messages.

**A traceback does not exempt a line** — only the first occurrence carries its
traceback, and the repeats are collapsed like any other. (An earlier exemption
was simply wrong: pyvisa logs a full traceback on *every* connect attempt, so a
dozen reconnects buried the log in hundreds of lines.) What is never suppressed
is `CRITICAL`.

## Never run Guppi under sudo

If an instrument needs a permission fix, **don't reach for `sudo`** — not on
`guppi rack`, not on the `guppi` CLI. It appears to work and leaves a mess:
every instrument ends up root-owned, so the problem returns for the next
person; the rack runs with privileges it has no use for; and a config saved
that way becomes root-owned, locking the non-root rack out of its own
`rig_config.yml`.

The supported fix for USB permissions is to **reinstall the rack**, which
refreshes the udev rule. Everything the rack genuinely needs elevated — owning
a USB node, adding an IP alias — it already does through narrow, validated
helpers installed for exactly that purpose.

If you must run the installer with sudo, run it from your own login
(`sudo guppi update`), never from inside a `sudo -i` root shell: the installer
reads the invoking user to decide whose `~/.guppi` to set up, and a root shell
makes it build the install for root.

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

- Is `guppi hub` running? The dashboard only exists while the hub runs — in the
  terminal you started it in. It does not come back on its own after a reboot or
  after that terminal closes; start it again with `guppi hub`.
- Page loads but says API-only / plain 404s: the UI bundle wasn't installed —
  re-run the installer (it fetches `guppi-ui-local.tar.gz` from the release).
- Loads but shows no live data: check the `guppi hub` terminal for NATS
  errors; the browser connects to port **9222** (WebSocket) on the same host —
  a firewall between you and the Pi must allow 8000, 9222, and 3010.
- Loads in one browser but not another: some browsers silently upgrade
  `http://` to `https://` (the hub doesn't serve TLS) — disable
  "always use secure connections" for this site, and check Shields/VPN/proxy
  extensions.

## Rig doesn't appear

- Is `guppi rack` actually running on the bench machine, and did it print a
  scan result? Instruments must be visible to it (USB permissions, Ethernet
  segment).
- A USB instrument visible to the OS but missing from the scan can be a
  permission problem: the rack installer grants serial/USB access via udev
  rules and applies them to already-attached devices. The rack also tries to
  re-own a mis-owned node itself at connect time, and says so in the log when
  that worked — so often there is nothing to do. If it couldn't, the error says
  "present on the USB bus but access denied". Re-run the installer to refresh
  the rule, or apply it to what's already attached without replugging:
  `sudo udevadm trigger --subsystem-match=usb --action=add`. Then restart
  `guppi rack`. Don't "fix" it by running the rack with sudo (see above).
- A **networked** instrument that won't appear is usually not a Guppi problem
  but an addressing one, and "No route to host" means nothing answered ARP on
  that subnet. The rack says which of three things is wrong — the port has a
  static IP (pin it with `ethernet.iface:`), nothing has aliased onto the
  subnet yet, or there's no free wired port. Read its IP off the front panel
  and declare it rather than adding aliases by hand.
- Separate rack machine: it must reach the hub — `curl http://<hub>:8000/health`
  from the rack box. If you paired against a raw LAN IP and the hub's address
  changed with a DHCP lease, edit `~/.guppi/config.env` to the `.local` mDNS
  name and restart `guppi rack`.
- Claim code entered but "rig offline": the rack keeps retrying — give it ~10 s,
  then check the rack terminal for connection errors.

## Rig is in the wrong place (cloud)

- Paired a rig under the wrong organization, or under your personal account
  instead of the team's? On the rigs overview in Guppi Cloud, hover the rig's
  card and use the transfer arrow — move it to one of your other orgs, or
  send it to another user by email (that also hands over pairing ownership).
  History moves with the rig. Only the account that paired the rig can
  transfer it — so if a teammate paired it, they run the transfer.

## Charts stop / data missing

- Telemetry is retained indefinitely — history is never auto-deleted, so
  missing charts are not a retention issue. Check the rack is connected and
  publishing, and that the signal path still matches.
- Check disk space: `df -h /var/lib/guppi`. A full disk stops ingest. Because
  history is kept indefinitely, reclaim space by pruning channels you no longer
  need from the Storage tab.

## Ports in use

Guppi assumes 8000 (hub), 4222/9222 (NATS), 3010 (PostgREST), and Postgres on
its distro default. If something else owns one of these, stop it or ask in an
issue — those aren't configurable in v0.

The rack additionally binds its health endpoint on **127.0.0.1:8080**, and that
one *is* configurable with `RACK_HOST` / `RACK_PORT`. "port 8080 is already in
use" almost always means a rack is already running: stop it
(`pkill -f src/main.py`) rather than moving the port.

## Starting over

```
# stop the hub first (Ctrl-C in the terminal running it)
GUPPI_PURGE_DATA=1 guppi uninstall
```

then re-run the installer. This deletes all recorded data. (Equivalent, if
`guppi` itself is broken: `curl -fsSL …/install.sh | sudo GUPPI_PURGE_DATA=1
bash -s -- --uninstall`.)
