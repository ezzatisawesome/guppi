#!/usr/bin/env bash
# ============================================================================
# Guppi installer — one command on a Raspberry Pi / Debian box:
#
#   curl -fsSL https://raw.githubusercontent.com/ezzatisawesome/guppi/main/install.sh | sudo bash
#
# (Canonical source lives in the monorepo at scripts/install.sh; the release
# workflow publishes it to the public distribution repo's root.)
#
# Installs the full offline bench (docs/single-pi-architecture.md §8.3):
#   • PostgreSQL (distro package, >= 15) — the one data path, local database
#   • PostgREST (release binary)        — the browser's read-only layer
#   • nats-server (release binary)      — the broker
#   • guppi hub (core agent, uv venv)   — ingest, commands, pairing, UI serving
#   • prebuilt UI bundle          — no Node runtime, no on-Pi build
# as systemd services (guppi-nats, guppi-postgrest, guppi-hub), storing data
# under /var/lib/guppi and serving the dashboard at http://<host>:8000.
# Zero cloud, zero account, zero login. Pair a bench by running
#   sudo bash /opt/guppi/src/packages/rack/install.sh
# on the machine wired to the instruments — on this same box it auto-claims
# over loopback.
#
# Pinning: default is the latest release tag; each release also attaches its
# own install.sh pre-pinned to that tag (the release workflow substitutes the
# GUPPI_REF default), so a pinned install is reproducible end-to-end.
# Re-running upgrades in place. STATUS: v0 — exercised on Debian bookworm
# arm64/amd64 paths by inspection; treat first run on new hardware as a test.
#
# KNOWN v0 LIMITATION (tracked in the doc §11): NATS runs with the anonymous
# dev config. The browser viewer is read-only by convention, not enforcement,
# until the installer grows local auth-callout key generation. On a trusted
# bench LAN this matches the "anyone may view" posture; hostile-LAN write
# protection lands with the callout wiring.
# ============================================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root:  curl ... | sudo bash"; exit 1; }

REPO="ezzatisawesome/guppi"
GUPPI_REF="${GUPPI_REF:-}"
GUPPI_HOME=/opt/guppi
GUPPI_DATA=/var/lib/guppi
GUPPI_ETC=/etc/guppi
RUN_USER=guppi

ARCH=$(uname -m)
case "$ARCH" in
  aarch64|arm64) PGRST_ARCH="ubuntu-aarch64"; NATS_ARCH="arm64" ;;
  x86_64)        PGRST_ARCH="linux-static-x86-64"; NATS_ARCH="amd64" ;;
  *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac

echo "── [1/7] System packages (PostgreSQL >= 15, curl, tar) ──"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates tar postgresql postgresql-client >/dev/null
PG_MAJOR=$(psql --version | awk '{split($3,v,"."); print v[1]}')
[ "$PG_MAJOR" -ge 15 ] || { echo "PostgreSQL >= 15 required (found $PG_MAJOR) — add pgdg and retry"; exit 1; }
systemctl enable --now postgresql >/dev/null

echo "── [2/7] Users & directories ──"
id -u "$RUN_USER" >/dev/null 2>&1 || useradd --system --create-home --home-dir "$GUPPI_DATA" "$RUN_USER"
mkdir -p "$GUPPI_HOME" "$GUPPI_DATA/artifacts" "$GUPPI_ETC"
chown -R "$RUN_USER:$RUN_USER" "$GUPPI_DATA"

echo "── [3/7] Fetch guppi source (${GUPPI_REF:-latest release}) ──"
# Everything installs from PUBLIC release assets on github.com/$REPO — no
# account, no token, no clone. guppi-src.tar.gz is the public source subset
# (hub + rack), built and attached by the release workflow.
if [ -z "$GUPPI_REF" ]; then
  GUPPI_REF=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
    | grep -m1 '"tag_name"' | cut -d'"' -f4 || true)
  [ -n "$GUPPI_REF" ] || { echo "No public release found on $REPO — set GUPPI_REF to a tag"; exit 1; }
fi
echo "   ref: $GUPPI_REF"
curl -fsSL "https://github.com/$REPO/releases/download/$GUPPI_REF/guppi-src.tar.gz" \
  -o /tmp/guppi-src.tar.gz \
  || { echo "No guppi-src.tar.gz asset on release $GUPPI_REF"; exit 1; }
rm -rf "$GUPPI_HOME/src"; mkdir -p "$GUPPI_HOME/src"
tar -xzf /tmp/guppi-src.tar.gz -C "$GUPPI_HOME/src" --strip-components=1

echo "── [4/7] Prebuilt UI bundle ──"
rm -rf "$GUPPI_HOME/ui"; mkdir -p "$GUPPI_HOME/ui"
if curl -fsSL "https://github.com/$REPO/releases/download/$GUPPI_REF/guppi-ui-local.tar.gz" \
     -o /tmp/guppi-ui.tar.gz 2>/dev/null; then
  tar -xzf /tmp/guppi-ui.tar.gz -C "$GUPPI_HOME/ui"
  echo "   installed from release asset"
else
  echo "   WARNING: no UI asset for $GUPPI_REF — hub runs API-only. Build the"
  echo "   bundle on a dev box with:  make ui-local"
  echo "   then untar guppi-ui-local.tar.gz into $GUPPI_HOME/ui (chown guppi)"
fi

echo "── [5/7] nats-server + PostgREST binaries ──"
if ! command -v nats-server >/dev/null 2>&1; then
  NATS_VER=$(curl -fsSL "https://api.github.com/repos/nats-io/nats-server/releases/latest" | grep -m1 '"tag_name"' | cut -d'"' -f4)
  curl -fsSL "https://github.com/nats-io/nats-server/releases/download/$NATS_VER/nats-server-$NATS_VER-linux-$NATS_ARCH.tar.gz" \
    | tar -xz -C /tmp
  install -m755 /tmp/nats-server-*/nats-server /usr/local/bin/nats-server
fi
if ! command -v postgrest >/dev/null 2>&1; then
  PGRST_VER=$(curl -fsSL "https://api.github.com/repos/PostgREST/postgrest/releases/latest" | grep -m1 '"tag_name"' | cut -d'"' -f4)
  curl -fsSL "https://github.com/PostgREST/postgrest/releases/download/$PGRST_VER/postgrest-$PGRST_VER-$PGRST_ARCH.tar.xz" \
    | tar -xJ -C /usr/local/bin postgrest
fi

echo "── [6/7] Database + hub venv ──"
sudo -u postgres psql -qAt -c "SELECT 1 FROM pg_roles WHERE rolname='guppi'" | grep -q 1 \
  || sudo -u postgres createuser guppi
sudo -u postgres psql -qAt -c "SELECT 1 FROM pg_database WHERE datname='guppi'" | grep -q 1 \
  || sudo -u postgres createdb -O guppi guppi
sudo -u postgres psql -q -d guppi \
  -f "$GUPPI_HOME/src/packages/agent/infrastructure/schema/core.sql" \
  -f "$GUPPI_HOME/src/packages/agent/infrastructure/schema/local.sql"
sudo -u postgres psql -qc "ALTER DATABASE guppi SET synchronous_commit = off;"
sudo -u postgres psql -qc "GRANT ALL ON SCHEMA public TO guppi; GRANT ALL ON ALL TABLES IN SCHEMA public TO guppi;" guppi

# Local-socket auth, no passwords: the hub connects as system user 'guppi' →
# db role 'guppi' (peer, already default). PostgREST connects as
# 'guppi_authenticator' from the same system user, so peer can't match —
# grant it trust on the local socket for the guppi db only.
PG_HBA=$(sudo -u postgres psql -qAt -c "SHOW hba_file;")
if ! grep -q "guppi_authenticator" "$PG_HBA"; then
  sed -i "1i local   guppi   guppi_authenticator   trust" "$PG_HBA"
  systemctl reload postgresql
fi

command -v uv >/dev/null 2>&1 || curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh >/dev/null
# The tarball was extracted as root; uv sync (and the .venv it creates) run as
# $RUN_USER, so the tree must be theirs before syncing.
chown -R "$RUN_USER:$RUN_USER" "$GUPPI_HOME"
( cd "$GUPPI_HOME/src/packages/agent" && sudo -u "$RUN_USER" uv sync --no-dev -q )

cat > "$GUPPI_ETC/hub.env" <<EOF
# Guppi hub — local mode is an explicit opt-in (never inferred).
# Unix-socket DSN: peer auth (system user guppi → db role guppi), no password.
GUPPI_BACKEND=local
DATABASE_URL=postgresql://guppi@/guppi?host=/var/run/postgresql
GUPPI_DATA_DIR=$GUPPI_DATA
GUPPI_UI_DIR=$GUPPI_HOME/ui
EOF
chown "$RUN_USER:$RUN_USER" "$GUPPI_ETC/hub.env"; chmod 600 "$GUPPI_ETC/hub.env"

# PostgREST: read-only web_anon over the local socket.
cat > "$GUPPI_ETC/postgrest.conf" <<EOF
db-uri = "postgres://guppi_authenticator@/guppi?host=/var/run/postgresql"
db-schemas = "public"
db-anon-role = "web_anon"
server-host = "0.0.0.0"
server-port = 3010
db-max-rows = 10000
# Single-user (local mode): PostgREST's default pool of 10 backends wastes Pi RAM.
db-pool = 3
EOF

echo "── [7/7] systemd services ──"
cat > /etc/systemd/system/guppi-nats.service <<EOF
[Unit]
Description=Guppi NATS broker
After=network.target
[Service]
User=$RUN_USER
# nats.dev.conf's JetStream store_dir is relative (.nats-data) — anchor it in
# the data dir, not systemd's default cwd of / (unwritable for $RUN_USER).
WorkingDirectory=$GUPPI_DATA
ExecStart=/usr/local/bin/nats-server -c $GUPPI_HOME/src/packages/agent/infrastructure/nats/nats.dev.conf
Restart=always
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/guppi-postgrest.service <<EOF
[Unit]
Description=Guppi PostgREST (read-only browser layer)
After=postgresql.service
Requires=postgresql.service
[Service]
User=$RUN_USER
ExecStart=/usr/local/bin/postgrest $GUPPI_ETC/postgrest.conf
Restart=always
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/guppi-hub.service <<EOF
[Unit]
Description=Guppi hub (local mode)
After=guppi-nats.service postgresql.service
Requires=guppi-nats.service postgresql.service
[Service]
User=$RUN_USER
EnvironmentFile=$GUPPI_ETC/hub.env
WorkingDirectory=$GUPPI_HOME/src/packages/agent
ExecStart=$GUPPI_HOME/src/packages/agent/.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now guppi-nats guppi-postgrest guppi-hub

echo ""
echo "✓ Guppi installed."
echo "  Dashboard:  http://$(hostname -I 2>/dev/null | awk '{print $1}'):8000"
echo "  Bench:      sudo bash /opt/guppi/src/packages/rack/install.sh"
echo "              on the instrument machine, then run: guppi-rack"
echo "              (this box: it auto-claims over loopback — no code to type)"
echo "  Upgrade:    re-run this installer"
