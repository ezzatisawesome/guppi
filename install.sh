#!/usr/bin/env bash
# ============================================================================
# Guppi installer — one command on a Raspberry Pi / Debian box:
#
#   curl -fsSL https://raw.githubusercontent.com/ezzatisawesome/guppi/main/install.sh | sudo bash
#
# Uninstall:  ... | sudo bash -s -- --uninstall     (add GUPPI_PURGE_DATA=1
#             to also drop the database and /var/lib/guppi)
#
# (Canonical source lives in the monorepo at scripts/install.sh; the release
# workflow publishes it to the public distribution repo's root.)
#
# Installs the full offline bench (docs/single-pi-architecture.md §8.3):
#   • PostgreSQL (>= 15; distro package, or pgdg when the distro ships older)
#   • PostgREST (release binary)        — the browser's read-only layer
#   • nats-server (release binary)      — the broker
#   • guppi hub (core agent, uv venv)   — ingest, commands, pairing, UI serving
#   • prebuilt UI bundle                — no Node runtime, no on-Pi build
# as systemd services (guppi-nats, guppi-postgrest, guppi-hub), storing data
# under /var/lib/guppi and serving the dashboard at http://<host>:8000.
# Zero cloud, zero account, zero login. Pair a bench by running
#   sudo bash /opt/guppi/src/packages/rack/install.sh
# on the machine wired to the instruments — on this same box it auto-claims
# over loopback.
#
# Supported: Debian bookworm/bullseye, Ubuntu 20.04+, Raspberry Pi OS 64-bit,
# on arm64 or amd64, running systemd. 32-bit OS images (armhf/armv7l) are
# detected and refused with guidance — PostgREST has no 32-bit builds.
#
# Pinning: default is the latest release tag; each release also attaches its
# own install.sh pre-pinned to that tag (the release workflow substitutes the
# GUPPI_REF default), so a pinned install is reproducible end-to-end. Release
# assets are verified against the release's SHA256SUMS when present.
# Re-running upgrades in place: services quiesce during the swap, the previous
# tree is kept until the new hub answers, and a failed upgrade rolls back.
#
# Air-gapped / CI installs: set GUPPI_SRC_TARBALL (and optionally
# GUPPI_UI_TARBALL) to local tarball paths to skip the GitHub downloads.
#
# KNOWN v0 LIMITATION (tracked in the doc §11): NATS runs with the anonymous
# dev config. The browser viewer is read-only by convention, not enforcement,
# until the installer grows local auth-callout key generation. On a trusted
# bench LAN this matches the "anyone may view" posture; hostile-LAN write
# protection lands with the callout wiring.
# ============================================================================
set -Eeuo pipefail

fail() { echo ""; echo "✗ $*" >&2; exit 1; }
trap 'echo ""; echo "✗ Install failed at line $LINENO (see the message above)." >&2;
      echo "  Re-running the installer is safe — it picks up where it left off." >&2' ERR

[ "$(id -u)" -eq 0 ] || fail "Run as root:  curl ... | sudo bash"
cd /   # sudo -u postgres commands warn if cwd is unreadable (e.g. /root)

REPO="ezzatisawesome/guppi"
GUPPI_REF="${GUPPI_REF:-}"
GUPPI_HOME=/opt/guppi
GUPPI_DATA=/var/lib/guppi
GUPPI_ETC=/etc/guppi
RUN_USER=guppi

# ── Uninstall ────────────────────────────────────────────────────────────────
# Reverses everything this installer wrote. Data (the database and
# /var/lib/guppi) survives unless GUPPI_PURGE_DATA=1 — an uninstall shouldn't
# silently erase months of bench telemetry.
if [ "${1:-}" = "--uninstall" ] || [ "${GUPPI_UNINSTALL:-0}" = "1" ]; then
  echo "── Uninstalling guppi ──"
  systemctl disable --now guppi-hub guppi-postgrest guppi-nats 2>/dev/null || true
  rm -f /etc/systemd/system/guppi-hub.service \
        /etc/systemd/system/guppi-postgrest.service \
        /etc/systemd/system/guppi-nats.service
  systemctl daemon-reload
  rm -rf "$GUPPI_HOME" "$GUPPI_ETC"
  rm -f /usr/local/bin/nats-server /usr/local/bin/postgrest
  rm -f /etc/systemd/journald.conf.d/guppi.conf
  if [ "${GUPPI_PURGE_DATA:-0}" = "1" ]; then
    sudo -u postgres dropdb --if-exists guppi 2>/dev/null || true
    sudo -u postgres dropuser --if-exists guppi 2>/dev/null || true
    sudo -u postgres dropuser --if-exists guppi_authenticator 2>/dev/null || true
    sudo -u postgres dropuser --if-exists web_anon 2>/dev/null || true
    PG_HBA=$(sudo -u postgres psql -qAt -c "SHOW hba_file;" 2>/dev/null || true)
    [ -n "$PG_HBA" ] && [ -f "$PG_HBA" ] \
      && sed -i '/guppi_authenticator/d' "$PG_HBA" \
      && systemctl reload postgresql 2>/dev/null || true
    rm -rf "$GUPPI_DATA"
    userdel guppi 2>/dev/null || true
    echo "✓ Uninstalled (database and data purged)."
  else
    echo "✓ Uninstalled. Kept the database and $GUPPI_DATA — rerun with"
    echo "  GUPPI_PURGE_DATA=1 to remove them too. PostgreSQL itself stays."
  fi
  exit 0
fi

# ── Preflight: refuse early, clearly, instead of dying mid-install ──────────
command -v apt-get >/dev/null 2>&1 \
  || fail "apt-get not found — Guppi installs on Debian-family systems (Debian, Ubuntu, Raspberry Pi OS)."
[ -d /run/systemd/system ] \
  || fail "systemd is not running — containers/WSL without systemd can't host the Guppi services."

ARCH=$(uname -m)
case "$ARCH" in
  aarch64|arm64) PGRST_ARCH="ubuntu-aarch64"; NATS_ARCH="arm64" ;;
  x86_64)        PGRST_ARCH="linux-static-x86-64"; NATS_ARCH="amd64" ;;
  armv7l|armv6l)
    fail "32-bit OS detected ($ARCH). Guppi needs a 64-bit OS — on a Pi 4/5, flash the 64-bit Raspberry Pi OS image." ;;
  *) fail "Unsupported architecture: $ARCH (need arm64 or amd64)" ;;
esac
# Pi OS gotcha: 64-bit kernel over a 32-bit userland reports aarch64 but can't
# run arm64 binaries. Check what dpkg actually installs.
if [ "$ARCH" = "aarch64" ] && command -v dpkg >/dev/null 2>&1; then
  DPKG_ARCH=$(dpkg --print-architecture)
  [ "$DPKG_ARCH" = "arm64" ] \
    || fail "64-bit kernel but a $DPKG_ARCH (32-bit) userland — flash the 64-bit Raspberry Pi OS image."
fi

MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 99999)
[ "$MEM_MB" -ge 1800 ] || echo "   WARNING: ${MEM_MB}MB RAM — 2GB+ recommended; expect swapping under load."
DISK_MB=$(df -Pm /opt 2>/dev/null | awk 'NR==2{print $4}' || echo 99999)
[ "${DISK_MB:-99999}" -ge 2048 ] || echo "   WARNING: only ${DISK_MB}MB free on /opt — 2GB+ recommended."

# One installer at a time — two concurrent runs interleave apt, chown, and
# service restarts into a mess.
exec 9>/var/lock/guppi-install.lock
flock -n 9 || fail "Another guppi installer is already running."

# Downloads land in a private temp dir (no fixed /tmp names — no collisions,
# no symlink games) that's removed on any exit.
TMPD=$(mktemp -d /tmp/guppi-install.XXXXXX)
trap 'rm -rf "$TMPD"' EXIT

# All downloads retry; fetch to a FILE, never pipe into tar — a mid-stream
# hiccup inside a pipe under pipefail kills the whole script with no retry.
fetch() { curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 "$@"; }

# Latest release tag for a GitHub repo, with a known-good pinned fallback for
# when the unauthenticated GitHub API is rate-limited (60 req/hr per IP —
# easy to hit re-running the installer). Fetch the whole response into a
# variable FIRST, then parse: piping curl straight into `grep -m1` races
# (grep exits on first match, curl gets EPIPE = exit 23, pipefail kills us).
latest_tag() {
  local repo="$1" fallback="${2:-}" json tag
  if json=$(fetch "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null); then
    tag=$(grep -m1 '"tag_name"' <<<"$json" | cut -d'"' -f4 || true)
  fi
  if [ -z "${tag:-}" ]; then
    [ -n "$fallback" ] || return 1
    echo "   NOTE: GitHub API unavailable (rate limit?) — using pinned $repo $fallback" >&2
    tag="$fallback"
  fi
  echo "$tag"
}

# Verify a downloaded release asset against the release's SHA256SUMS (present
# on releases cut after checksums landed; older releases skip with a note).
verify_asset() {
  local name="$1"
  [ -f "$TMPD/SHA256SUMS" ] || return 0
  if ! grep -q " $name\$" "$TMPD/SHA256SUMS"; then
    echo "   NOTE: $name not in SHA256SUMS — skipping verification"
    return 0
  fi
  (cd "$TMPD" && grep " $name\$" SHA256SUMS | sha256sum -c - >/dev/null) \
    || fail "$name failed checksum verification against $GUPPI_REF's SHA256SUMS"
  echo "   $name: checksum OK"
}

# apt on a freshly booted Pi: unattended-upgrades often holds the dpkg lock
# for the first minutes. Wait for it instead of dying.
APT="apt-get -o DPkg::Lock::Timeout=180 -qq"

echo "── [1/7] System packages (PostgreSQL >= 15, curl, tar) ──"
export DEBIAN_FRONTEND=noninteractive
$APT update || echo "   WARNING: apt-get update reported errors — continuing with cached package lists"
$APT install -y curl ca-certificates tar xz-utils postgresql postgresql-client >/dev/null

# Distro PostgreSQL too old (Ubuntu 22.04 ships 14, bullseye 13)? Add the
# official pgdg repo via the helper postgresql-common ships, install current.
PG_MAJOR=$(psql --version | awk '{split($3,v,"."); print v[1]}')
if [ "$PG_MAJOR" -lt 15 ]; then
  echo "   distro PostgreSQL is $PG_MAJOR — adding the official pgdg repo for a current version"
  $APT install -y postgresql-common >/dev/null
  if [ -x /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh ]; then
    /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y >/dev/null \
      || fail "Couldn't add the pgdg apt repo. Add PostgreSQL >= 15 manually and re-run."
  else
    # Older postgresql-common (e.g. Ubuntu 22.04) predates the helper — add
    # the repo by hand: signing key + one sources.list.d entry.
    install -d /usr/share/postgresql-common/pgdg
    fetch -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
      https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      || fail "Couldn't fetch the pgdg signing key. Add PostgreSQL >= 15 manually and re-run."
    CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $CODENAME-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list
  fi
  $APT update || true
  $APT install -y postgresql-17 postgresql-client-17 >/dev/null
fi
systemctl enable --now postgresql >/dev/null

# Installing the server package normally auto-creates a cluster — but some
# images (GitHub runners; possibly trimmed distro spins) ship postgresql-common
# with cluster auto-creation disabled. If no >= 15 cluster exists, create one
# from the newest installed >= 15 binaries.
if ! pg_lsclusters --no-header 2>/dev/null | awk '$1+0>=15{f=1} END{exit !f}'; then
  NEWEST=$(ls /usr/lib/postgresql 2>/dev/null | awk '$1+0>=15' | sort -n | tail -1)
  [ -n "$NEWEST" ] || { pg_lsclusters 2>&1 || true; fail "No PostgreSQL >= 15 installed — clusters above."; }
  echo "   no cluster exists — creating $NEWEST/main"
  pg_createcluster "$NEWEST" main >/dev/null \
    || { pg_lsclusters 2>&1 || true; fail "pg_createcluster $NEWEST main failed."; }
fi

# Boxes can carry several clusters (distro 14 + pgdg 17 side by side, each on
# its own port). Target the newest >= 15 cluster explicitly, by port.
read -r PG_VER PG_CLUSTER PG_PORT <<<"$(pg_lsclusters --no-header 2>/dev/null \
  | awk '$1+0>=15 {v=$1; c=$2; p=$3} END{print v, c, p}')"
[ -n "${PG_PORT:-}" ] || { pg_lsclusters 2>&1 || true; fail "No PostgreSQL >= 15 cluster found after install (clusters above)."; }
pg_ctlcluster "$PG_VER" "$PG_CLUSTER" start 2>/dev/null || true
for _ in $(seq 1 30); do
  sudo -u postgres pg_isready -q -p "$PG_PORT" 2>/dev/null && break; sleep 1
done
sudo -u postgres pg_isready -q -p "$PG_PORT" \
  || fail "PostgreSQL cluster $PG_VER/$PG_CLUSTER (port $PG_PORT) didn't come up — check: journalctl -u postgresql"
echo "   using PostgreSQL $PG_VER (cluster $PG_CLUSTER, port $PG_PORT)"
PSQL="sudo -u postgres psql -p $PG_PORT"

# Appliance hygiene: journald grows until it eats the SD card. Cap it.
if [ ! -f /etc/systemd/journald.conf.d/guppi.conf ]; then
  mkdir -p /etc/systemd/journald.conf.d
  printf '# Guppi appliance: keep logs from filling the SD card.\n[Journal]\nSystemMaxUse=200M\n' \
    > /etc/systemd/journald.conf.d/guppi.conf
  systemctl try-restart systemd-journald 2>/dev/null || true
fi

echo "── [2/7] Users & directories ──"
id -u "$RUN_USER" >/dev/null 2>&1 || useradd --system --create-home --home-dir "$GUPPI_DATA" "$RUN_USER"
mkdir -p "$GUPPI_HOME" "$GUPPI_DATA/artifacts" "$GUPPI_ETC"
chown -R "$RUN_USER:$RUN_USER" "$GUPPI_DATA"

echo "── [3/7] Fetch guppi source (${GUPPI_REF:-latest release}) ──"
# Everything installs from PUBLIC release assets on github.com/$REPO — no
# account, no token, no clone. guppi-src.tar.gz is the public source subset
# (hub + rack), built and attached by the release workflow.
if [ -n "${GUPPI_SRC_TARBALL:-}" ]; then
  # Air-gapped / CI path: a local tarball replaces the download.
  GUPPI_REF="${GUPPI_REF:-local}"
  echo "   using local tarball: $GUPPI_SRC_TARBALL"
  cp "$GUPPI_SRC_TARBALL" "$TMPD/guppi-src.tar.gz"
else
  if [ -z "$GUPPI_REF" ]; then
    GUPPI_REF=$(latest_tag "$REPO" || true)
    [ -n "$GUPPI_REF" ] || fail "No public release found on $REPO — set GUPPI_REF to a tag (GitHub API may be rate-limited; retry in a few minutes)"
  fi
  echo "   ref: $GUPPI_REF"
  DL="https://github.com/$REPO/releases/download/$GUPPI_REF"
  fetch -o "$TMPD/SHA256SUMS" "$DL/SHA256SUMS" 2>/dev/null \
    || echo "   NOTE: no SHA256SUMS on $GUPPI_REF (pre-checksum release) — skipping verification"
  fetch -o "$TMPD/guppi-src.tar.gz" "$DL/guppi-src.tar.gz" \
    || fail "No guppi-src.tar.gz asset on release $GUPPI_REF"
  verify_asset guppi-src.tar.gz
fi

# Upgrades: quiesce services and keep the old tree (and its venv) as
# src.prev until the new hub proves healthy — a failed upgrade rolls back.
UPGRADING=0
if [ -d "$GUPPI_HOME/src" ]; then
  UPGRADING=1
  PREV_REF=$(cat "$GUPPI_ETC/version" 2>/dev/null || echo "unknown")
  echo "   upgrading from $PREV_REF"
  systemctl stop guppi-hub guppi-postgrest guppi-nats 2>/dev/null || true
  rm -rf "$GUPPI_HOME/src.prev" "$GUPPI_HOME/ui.prev"
  mv "$GUPPI_HOME/src" "$GUPPI_HOME/src.prev"
  if [ -d "$GUPPI_HOME/ui" ]; then mv "$GUPPI_HOME/ui" "$GUPPI_HOME/ui.prev"; fi
fi
mkdir -p "$GUPPI_HOME/src"
tar -xzf "$TMPD/guppi-src.tar.gz" -C "$GUPPI_HOME/src" --strip-components=1

echo "── [4/7] Prebuilt UI bundle ──"
rm -rf "$GUPPI_HOME/ui"; mkdir -p "$GUPPI_HOME/ui"
if [ -n "${GUPPI_UI_TARBALL:-}" ]; then
  tar -xzf "$GUPPI_UI_TARBALL" -C "$GUPPI_HOME/ui"
  echo "   installed from local tarball"
elif [ -z "${GUPPI_SRC_TARBALL:-}" ] \
     && fetch -o "$TMPD/guppi-ui-local.tar.gz" "$DL/guppi-ui-local.tar.gz" 2>/dev/null; then
  verify_asset guppi-ui-local.tar.gz
  tar -xzf "$TMPD/guppi-ui-local.tar.gz" -C "$GUPPI_HOME/ui"
  echo "   installed from release asset"
else
  echo "   WARNING: no UI bundle — hub runs API-only. Build the bundle on a"
  echo "   dev box with:  make ui-local"
  echo "   then untar guppi-ui-local.tar.gz into $GUPPI_HOME/ui (chown guppi)"
fi

echo "── [5/7] nats-server + PostgREST binaries ──"
if ! command -v nats-server >/dev/null 2>&1; then
  NATS_VER=$(latest_tag nats-io/nats-server v2.14.3)
  fetch -o "$TMPD/nats.tar.gz" \
    "https://github.com/nats-io/nats-server/releases/download/$NATS_VER/nats-server-$NATS_VER-linux-$NATS_ARCH.tar.gz" \
    || fail "Couldn't download nats-server $NATS_VER"
  tar -xzf "$TMPD/nats.tar.gz" -C "$TMPD"
  install -m755 "$TMPD"/nats-server-*/nats-server /usr/local/bin/nats-server
fi
if ! command -v postgrest >/dev/null 2>&1; then
  PGRST_VER=$(latest_tag PostgREST/postgrest v14.15)
  fetch -o "$TMPD/postgrest.tar.xz" \
    "https://github.com/PostgREST/postgrest/releases/download/$PGRST_VER/postgrest-$PGRST_VER-$PGRST_ARCH.tar.xz" \
    || fail "Couldn't download PostgREST $PGRST_VER"
  tar -xJf "$TMPD/postgrest.tar.xz" -C /usr/local/bin postgrest
fi

echo "── [6/7] Database + hub venv ──"
$PSQL -qAt -c "SELECT 1 FROM pg_roles WHERE rolname='guppi'" | grep -q 1 \
  || sudo -u postgres createuser -p "$PG_PORT" guppi
$PSQL -qAt -c "SELECT 1 FROM pg_database WHERE datname='guppi'" | grep -q 1 \
  || sudo -u postgres createdb -p "$PG_PORT" -O guppi guppi
$PSQL -q -d guppi \
  -f "$GUPPI_HOME/src/packages/agent/infrastructure/schema/core.sql" \
  -f "$GUPPI_HOME/src/packages/agent/infrastructure/schema/local.sql"
$PSQL -qc "ALTER DATABASE guppi SET synchronous_commit = off;"
$PSQL -qc "GRANT ALL ON SCHEMA public TO guppi; GRANT ALL ON ALL TABLES IN SCHEMA public TO guppi;" guppi

# Local-socket auth, no passwords: the hub connects as system user 'guppi' →
# db role 'guppi' (peer, already default). PostgREST connects as
# 'guppi_authenticator' from the same system user, so peer can't match —
# grant it trust on the local socket for the guppi db only.
PG_HBA=$($PSQL -qAt -c "SHOW hba_file;")
if ! grep -q "guppi_authenticator" "$PG_HBA"; then
  sed -i "1i local   guppi   guppi_authenticator   trust" "$PG_HBA"
  systemctl reload postgresql
fi

command -v uv >/dev/null 2>&1 \
  || { fetch https://astral.sh/uv/install.sh -o "$TMPD/uv-install.sh" \
       && env UV_INSTALL_DIR=/usr/local/bin sh "$TMPD/uv-install.sh" >/dev/null; } \
  || fail "Couldn't install uv"
# The tarball was extracted as root; uv sync (and the .venv it creates) run as
# $RUN_USER, so the tree must be theirs before syncing. --frozen: install
# exactly the shipped uv.lock, no resolution drift. Retry once — PyPI fetches
# on Pi wifi flake.
chown -R "$RUN_USER:$RUN_USER" "$GUPPI_HOME"
( cd "$GUPPI_HOME/src/packages/agent" \
  && { sudo -u "$RUN_USER" uv sync --frozen --no-dev -q \
       || { echo "   uv sync failed — retrying once"; sleep 3; sudo -u "$RUN_USER" uv sync --frozen --no-dev -q; }; } )

cat > "$GUPPI_ETC/hub.env" <<EOF
# Guppi hub — local mode is an explicit opt-in (never inferred).
# Unix-socket DSN: peer auth (system user guppi → db role guppi), no password.
GUPPI_BACKEND=local
DATABASE_URL=postgresql://guppi@/guppi?host=/var/run/postgresql&port=$PG_PORT
GUPPI_DATA_DIR=$GUPPI_DATA
GUPPI_UI_DIR=$GUPPI_HOME/ui
EOF
chown "$RUN_USER:$RUN_USER" "$GUPPI_ETC/hub.env"; chmod 600 "$GUPPI_ETC/hub.env"

# PostgREST: read-only web_anon over the local socket.
cat > "$GUPPI_ETC/postgrest.conf" <<EOF
db-uri = "postgres://guppi_authenticator@/guppi?host=/var/run/postgresql&port=$PG_PORT"
db-schemas = "public"
db-anon-role = "web_anon"
server-host = "0.0.0.0"
server-port = 3010
db-max-rows = 10000
# Single-user (local mode): PostgREST's default pool of 10 backends wastes Pi RAM.
db-pool = 3
EOF

echo "── [7/7] systemd services ──"
# Shared unit posture: restart forever (StartLimitIntervalSec=0 — an appliance
# must never wedge in systemd's start-limit state after a flaky boot), small
# backoff, and no privilege escalation from the service user.
cat > /etc/systemd/system/guppi-nats.service <<EOF
[Unit]
Description=Guppi NATS broker
After=network.target
StartLimitIntervalSec=0
[Service]
User=$RUN_USER
# nats.dev.conf's JetStream store_dir is relative (.nats-data) — anchor it in
# the data dir, not systemd's default cwd of / (unwritable for $RUN_USER).
WorkingDirectory=$GUPPI_DATA
ExecStart=/usr/local/bin/nats-server -c $GUPPI_HOME/src/packages/agent/infrastructure/nats/nats.dev.conf
Restart=always
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/guppi-postgrest.service <<EOF
[Unit]
Description=Guppi PostgREST (read-only browser layer)
After=postgresql.service
Requires=postgresql.service
StartLimitIntervalSec=0
[Service]
User=$RUN_USER
ExecStart=/usr/local/bin/postgrest $GUPPI_ETC/postgrest.conf
Restart=always
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/guppi-hub.service <<EOF
[Unit]
Description=Guppi hub (local mode)
After=guppi-nats.service postgresql.service
Requires=guppi-nats.service postgresql.service
StartLimitIntervalSec=0
[Service]
User=$RUN_USER
EnvironmentFile=$GUPPI_ETC/hub.env
WorkingDirectory=$GUPPI_HOME/src/packages/agent
ExecStart=$GUPPI_HOME/src/packages/agent/.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000
Restart=always
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable guppi-nats guppi-postgrest guppi-hub >/dev/null
systemctl restart guppi-nats guppi-postgrest guppi-hub

# Don't claim success until the hub actually answers (any HTTP status means
# the process is up and serving; UI-less installs 404 on / and that's fine).
hub_up() {
  local code
  for _ in $(seq 1 "${1:-30}"); do
    code=$(curl -so /dev/null -w '%{http_code}' http://localhost:8000/ 2>/dev/null || true)
    [ -n "$code" ] && [ "$code" != "000" ] && return 0
    sleep 1
  done
  return 1
}

if ! hub_up 30; then
  echo "" >&2
  journalctl -u guppi-hub -n 20 --no-pager 2>/dev/null >&2 || true
  if [ "$UPGRADING" = 1 ] && [ -d "$GUPPI_HOME/src.prev" ]; then
    # Roll back to the previous tree (with its venv). The schema was already
    # re-applied for the new version — schema changes are additive, so the
    # old hub keeps working against it.
    echo "" >&2
    echo "✗ Upgraded hub didn't come up — rolling back to $PREV_REF" >&2
    systemctl stop guppi-hub guppi-postgrest guppi-nats 2>/dev/null || true
    rm -rf "$GUPPI_HOME/src"; mv "$GUPPI_HOME/src.prev" "$GUPPI_HOME/src"
    if [ -d "$GUPPI_HOME/ui.prev" ]; then
      rm -rf "$GUPPI_HOME/ui"; mv "$GUPPI_HOME/ui.prev" "$GUPPI_HOME/ui"
    fi
    systemctl restart guppi-nats guppi-postgrest guppi-hub
    hub_up 30 && echo "✓ Rollback succeeded — $PREV_REF is running." >&2 \
      || echo "✗ Rollback didn't come up either — check: journalctl -u guppi-hub" >&2
    fail "Upgrade to $GUPPI_REF failed (rolled back). Journal excerpt above."
  fi
  fail "Hub didn't answer on :8000 within 30s — journal excerpt above; more: journalctl -u guppi-hub -n 50"
fi
rm -rf "$GUPPI_HOME/src.prev" "$GUPPI_HOME/ui.prev"
echo "$GUPPI_REF" > "$GUPPI_ETC/version"

# Secondary services: the hub is the gate; these get a warning, not a failure.
systemctl is-active --quiet guppi-nats \
  || echo "   WARNING: guppi-nats is not running — check: journalctl -u guppi-nats"
curl -fsS -o /dev/null http://localhost:3010/ 2>/dev/null \
  || echo "   WARNING: PostgREST not answering on :3010 — check: journalctl -u guppi-postgrest"

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo ""
echo "✓ Guppi $GUPPI_REF installed."
echo "  Dashboard:  http://${IP:-<this-host>}:8000"
echo "  Bench:      sudo bash /opt/guppi/src/packages/rack/install.sh"
echo "              on the instrument machine, then run: guppi-rack"
echo "              (this box: it auto-claims over loopback — no code to type)"
echo "  Upgrade:    re-run this installer"
if [ "$UPGRADING" = 1 ] && [ -x /usr/local/bin/guppi-rack ]; then
  echo ""
  echo "  NOTE: the source tree was replaced and the rack venv with it —"
  echo "        re-run:  sudo bash /opt/guppi/src/packages/rack/install.sh"
fi
