#Requires -Version 5.1
<#
Guppi bench installer for Windows: the hub and the rack, for you, without
administrator rights.

    irm https://github.com/ezzatisawesome/guppi/releases/latest/download/install.ps1 | iex

Everything lands in %LOCALAPPDATA%\Guppi and your user PATH; nothing is
installed system-wide and nothing runs as a service. Run `guppi up` to start
the bench (Ctrl-C stops it), or `guppi hub` / `guppi rack` on their own. The
rack's settings live in %USERPROFILE%\.guppi, as on Linux.

    src\      the release (hub, rack, CLI) and their Python environments
    pgsql\    a private PostgreSQL, on 127.0.0.1 only, password-protected
    bin\      guppi, guppi-hub, guppi-rack, nats-server, postgrest, uv
    etc\      hub.env (where everything is), postgrest.conf, db.secret
    data\     the database cluster, NATS's store, run artifacts

Re-running upgrades in place (stop the bench first); a failed upgrade rolls
back. Options: -Ref <tag>, -SrcTarball <path> (offline), -Uninstall [-Purge].
Windows on ARM runs the x64 build under emulation: several of the hub's
Python dependencies have no ARM64 wheels.
#>
param(
    [string]$Ref = $env:GUPPI_REF,
    [string]$SrcTarball = $env:GUPPI_SRC_TARBALL,
    [string]$UiTarball = $env:GUPPI_UI_TARBALL,
    [switch]$Uninstall,
    [switch]$Purge
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # the progress bar makes downloads 10x slower
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo = 'ezzatisawesome/guppi'
$Root = Join-Path $env:LOCALAPPDATA 'Guppi'
$Bin, $Etc, $Data = "$Root\bin", "$Root\etc", "$Root\data"
$PgDist, $PgData = "$Root\pgsql", "$Root\data\pg"
$RackHome = Join-Path $env:USERPROFILE '.guppi'
# A cluster's data directory belongs to one Postgres major, so an existing
# install keeps the binaries it was created with; only a new one gets these.
$PgVersion = '18.6.1'
$PgPort = 55432  # off 5432, so a Postgres already on this machine is left alone
# Pinned fallbacks for when the GitHub API rate-limits us (60/hour per IP).
$NatsFallback, $PostgrestFallback, $UvFallback = 'v2.15.2', 'v16.5', '0.13.7'
# One interpreter for every venv, x64 everywhere (see above).
$env:UV_PYTHON = 'cpython-3.12-windows-x86_64-none'
$env:UV_PYTHON_INSTALL_DIR = "$Root\python"
$env:UV_CACHE_DIR = "$Root\cache\uv"

# Never `exit`: run as `irm ... | iex`, it would close the user's window and
# the message with it. A throw ends the install, and -File still exits 1.
function Fail([string]$msg) {
    Write-Host ''
    Write-Host "x $msg" -ForegroundColor Red
    Write-Host '  Re-running the installer is safe: it picks up where it left off.'
    throw "Guppi install failed: $msg"
}
function Step([string]$msg) { Write-Host "-- $msg --" -ForegroundColor Cyan }
function Note([string]$msg) { Write-Host "   $msg" }

function Fetch([string]$url, [string]$out) {
    for ($i = 1; $i -le 3; $i++) {
        try { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $out; return }
        catch { if ($i -eq 3) { throw } ; Start-Sleep -Seconds (2 * $i) }
    }
}

function LatestTag([string]$repo, [string]$fallback) {
    try {
        return (Invoke-RestMethod -UseBasicParsing "https://api.github.com/repos/$repo/releases/latest").tag_name
    } catch {
        if (-not $fallback) { throw }
        Note "GitHub API unavailable (rate limit?): using pinned $repo $fallback"
        return $fallback
    }
}

function Verify([string]$file, [string]$expected) {
    $actual = (Get-FileHash -Algorithm SHA256 $file).Hash.ToLower()
    if ($actual -ne $expected.ToLower()) { Fail "$(Split-Path -Leaf $file) failed its checksum" }
}

# The hash for $name from a SHA256SUMS-style file ("<hash>  <name>"), or $null.
function SumFor([string]$sums, [string]$name) {
    if (-not (Test-Path $sums)) { return $null }
    foreach ($line in Get-Content $sums) {
        $parts = $line -split '\s+', 2
        if ($parts.Count -eq 2 -and $parts[1].TrimStart('*') -eq $name) { return $parts[0] }
    }
    return $null
}

function HubAnswers {
    try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 'http://127.0.0.1:8000/' | Out-Null; return $true }
    catch { return [bool]$_.Exception.Response }  # an HTTP error still means something answered
}

function Secret {
    $bytes = New-Object byte[] 24
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

function Run([string]$exe, [string[]]$argv, [string]$what) {
    & $exe @argv
    if ($LASTEXITCODE -ne 0) { Fail "$what failed (exit $LASTEXITCODE)" }
}

# UTF-8 without a byte-order mark (5.1's -Encoding utf8 writes one, which
# PostgREST's config parser rejects), so a non-ASCII user name survives too.
function WriteText([string]$path, [string]$text) {
    if ($path.EndsWith('.cmd')) { $text = $text -replace "`r?`n", "`r`n" }  # cmd.exe wants CRLF
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false))
}

function UserPath([string]$dir, [bool]$add) {
    $parts = @(([Environment]::GetEnvironmentVariable('Path', 'User') -split ';') |
               Where-Object { $_ -and $_ -ne $dir })
    if ($add) { $parts = @($dir) + $parts }
    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
    if ($add -and ($env:Path -split ';') -notcontains $dir) { $env:Path = "$dir;$env:Path" }
}

# ── Uninstall ────────────────────────────────────────────────────────────────
if ($Uninstall) {
    if (HubAnswers) { Fail 'the hub is running: stop it (Ctrl-C where guppi up or guppi hub runs) first.' }
    UserPath $Bin $false
    if ($Purge) {
        Remove-Item -Recurse -Force $Root -ErrorAction SilentlyContinue
        Write-Host "Uninstalled, and deleted the database and settings in $Root."
    } else {
        foreach ($d in 'src', 'src.prev', 'ui', 'bin', 'python', 'cache', 'pgsql') {
            Remove-Item -Recurse -Force "$Root\$d" -ErrorAction SilentlyContinue
        }
        Write-Host "Uninstalled. Your data stays in $Data and $RackHome (-Purge removes $Root)."
    }
    return
}

# ── Preflight ────────────────────────────────────────────────────────────────
if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
    Fail 'tar.exe is missing: Guppi needs Windows 10 version 1803 or later.'
}
if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
    Note 'Windows on ARM: installing the x64 build, which runs under emulation.'
}
if (HubAnswers) { Fail 'the hub is running: stop it (Ctrl-C where guppi up or guppi hub runs), then re-run.' }

New-Item -ItemType Directory -Force $Root, $Bin, $Etc, $Data, "$Data\artifacts", $RackHome | Out-Null
$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("guppi-install-" + [guid]::NewGuid())
New-Item -ItemType Directory $Tmp | Out-Null
try {

# ── 1. The release ───────────────────────────────────────────────────────────
Step '1/7 Guppi release'
if ($SrcTarball) {
    if (-not $Ref) { $Ref = 'local' }
    Copy-Item $SrcTarball "$Tmp\guppi-src.tar.gz"
    Note "using $SrcTarball"
} else {
    if (-not $Ref) { $Ref = LatestTag $Repo '' }
    $dl = "https://github.com/$Repo/releases/download/$Ref"
    Note "release $Ref"
    try { Fetch "$dl/SHA256SUMS" "$Tmp\SHA256SUMS" } catch { Note 'no SHA256SUMS on this release: skipping verification' }
    Fetch "$dl/guppi-src.tar.gz" "$Tmp\guppi-src.tar.gz"
    $sum = SumFor "$Tmp\SHA256SUMS" 'guppi-src.tar.gz'
    if ($sum) { Verify "$Tmp\guppi-src.tar.gz" $sum; Note 'guppi-src.tar.gz: checksum OK' }
    if (-not $UiTarball) {
        try {
            Fetch "$dl/guppi-ui-local.tar.gz" "$Tmp\guppi-ui-local.tar.gz"
            $sum = SumFor "$Tmp\SHA256SUMS" 'guppi-ui-local.tar.gz'
            if ($sum) { Verify "$Tmp\guppi-ui-local.tar.gz" $sum }
            $UiTarball = "$Tmp\guppi-ui-local.tar.gz"
        } catch { Note 'no UI bundle on this release: the hub runs API-only' }
    }
}

$upgrading = Test-Path "$Root\src"
if ($upgrading) {
    $prevRef = if (Test-Path "$Etc\version") { Get-Content "$Etc\version" } else { 'unknown' }
    Note "upgrading from $prevRef"
    if (Test-Path "$Root\src.prev") {
        Note '(recovering from an interrupted update: keeping the last good tree)'
        Remove-Item -Recurse -Force "$Root\src", "$Root\ui" -ErrorAction SilentlyContinue
    } else {
        Move-Item "$Root\src" "$Root\src.prev"
        if (Test-Path "$Root\ui") { Move-Item "$Root\ui" "$Root\ui.prev" }
    }
}
New-Item -ItemType Directory -Force "$Root\src", "$Root\ui" | Out-Null
Run tar.exe @('-xzf', "$Tmp\guppi-src.tar.gz", '-C', "$Root\src", '--strip-components=1') 'extracting the release'
if ($UiTarball) { Run tar.exe @('-xzf', $UiTarball, '-C', "$Root\ui") 'extracting the UI' }
$Agent, $Cli, $Rack = "$Root\src\packages\agent", "$Root\src\packages\cli", "$Root\src\packages\rack"

# ── 2. Tools: uv, nats-server, PostgREST ─────────────────────────────────────
Step '2/7 uv, nats-server, PostgREST'
$uvTag = LatestTag 'astral-sh/uv' $UvFallback
$uvZip = 'uv-x86_64-pc-windows-msvc.zip'
Fetch "https://github.com/astral-sh/uv/releases/download/$uvTag/$uvZip" "$Tmp\uv.zip"
Fetch "https://github.com/astral-sh/uv/releases/download/$uvTag/$uvZip.sha256" "$Tmp\uv.sha256"
Verify "$Tmp\uv.zip" ((Get-Content "$Tmp\uv.sha256") -split '\s+')[0]
Expand-Archive -Force "$Tmp\uv.zip" "$Tmp\uv"
Copy-Item -Force "$Tmp\uv\uv.exe" "$Bin\uv.exe"

$natsTag = LatestTag 'nats-io/nats-server' $NatsFallback
$natsZip = "nats-server-$natsTag-windows-amd64.zip"
Fetch "https://github.com/nats-io/nats-server/releases/download/$natsTag/$natsZip" "$Tmp\nats.zip"
Fetch "https://github.com/nats-io/nats-server/releases/download/$natsTag/SHA256SUMS" "$Tmp\nats.sums"
$sum = SumFor "$Tmp\nats.sums" $natsZip
if (-not $sum) { Fail "no checksum for $natsZip" }
Verify "$Tmp\nats.zip" $sum
Expand-Archive -Force "$Tmp\nats.zip" "$Tmp\nats"
Copy-Item -Force (Get-ChildItem -Recurse "$Tmp\nats" -Filter nats-server.exe | Select-Object -First 1).FullName "$Bin\nats-server.exe"

$pgrstTag = LatestTag 'PostgREST/postgrest' $PostgrestFallback
# PostgREST publishes no checksums; the download is over TLS from its own releases.
Fetch "https://github.com/PostgREST/postgrest/releases/download/$pgrstTag/postgrest-$pgrstTag-windows-x86-64.zip" "$Tmp\postgrest.zip"
Expand-Archive -Force "$Tmp\postgrest.zip" "$Tmp\postgrest"
Copy-Item -Force "$Tmp\postgrest\postgrest.exe" "$Bin\postgrest.exe"
Note "uv $uvTag, nats-server $natsTag, PostgREST $pgrstTag"

# ── 3. PostgreSQL ────────────────────────────────────────────────────────────
Step '3/7 PostgreSQL'
if (-not (Test-Path "$PgDist\bin\postgres.exe")) {
    $pgZip = "postgresql-$PgVersion-x86_64-pc-windows-msvc.zip"
    $base = "https://github.com/theseus-rs/postgresql-binaries/releases/download/$PgVersion"
    Fetch "$base/$pgZip" "$Tmp\pg.zip"
    Fetch "$base/$pgZip.sha256" "$Tmp\pg.sha256"
    Verify "$Tmp\pg.zip" ((Get-Content "$Tmp\pg.sha256") -split '\s+')[0]
    Expand-Archive -Force "$Tmp\pg.zip" "$Tmp\pg"
    Move-Item (Get-ChildItem "$Tmp\pg" -Directory | Select-Object -First 1).FullName $PgDist
    Note "PostgreSQL $PgVersion"
} else {
    Note 'keeping the installed PostgreSQL (its cluster is tied to its version)'
}
$PgBin = "$PgDist\bin"

# One secret file, kept across upgrades: the database's three passwords.
$secretFile = "$Etc\db.secret"
if (Test-Path $secretFile) {
    $secret = Get-Content $secretFile -Raw | ConvertFrom-Json
} else {
    $secret = [pscustomobject]@{ postgres = (Secret); guppi = (Secret); authenticator = (Secret) }
    $secret | ConvertTo-Json | Set-Content -Encoding ascii $secretFile
}

if (-not (Test-Path "$PgData\PG_VERSION")) {
    $pw = "$Tmp\pw"
    WriteText $pw $secret.postgres  # not Set-Content -NoNewline: on 5.1 that wrote no file at all
    Run "$PgBin\initdb.exe" @('-D', $PgData, '-U', 'postgres', "--pwfile=$pw", '-E', 'UTF8',
                              '--no-locale', '--auth=scram-sha-256') 'creating the database cluster'
    Remove-Item $pw
    Add-Content -Encoding ascii "$PgData\postgresql.conf" @"

# Guppi: this machine only, on its own port.
listen_addresses = '127.0.0.1'
port = $PgPort
"@
    Note "created the cluster in $PgData"
}

# ── 4. Python environments ───────────────────────────────────────────────────
Step '4/7 Python environments (the first run downloads Python)'
foreach ($pkg in @(@($Agent, 'import fastapi, uvicorn, asyncpg'), @($Cli, 'import guppi_cli.hub'),
                   @($Rack, 'import pyvisa, serial'))) {
    $dir, $check = $pkg
    Push-Location $dir
    try {
        & "$Bin\uv.exe" sync --frozen --no-dev -q
        if ($LASTEXITCODE -ne 0) {
            Note "uv sync failed in $(Split-Path -Leaf $dir): clearing its venv and retrying once"
            Remove-Item -Recurse -Force .venv -ErrorAction SilentlyContinue
            Run "$Bin\uv.exe" @('sync', '--frozen', '--no-dev', '-q') "building the $(Split-Path -Leaf $dir) venv"
        }
        Run ".venv\Scripts\python.exe" @('-c', $check) "the $(Split-Path -Leaf $dir) venv doesn't import"
    } finally { Pop-Location }
}

# ── 5. Database: roles, schema ───────────────────────────────────────────────
Step '5/7 Database'
$env:PGPASSWORD = $secret.postgres
Run "$PgBin\pg_ctl.exe" @('-D', $PgData, '-l', "$Data\pg-install.log", '-w', 'start') 'starting PostgreSQL'
try {
    $psql = @('-h', '127.0.0.1', '-p', "$PgPort", '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-qAt')
    $hasDb = & "$PgBin\psql.exe" @psql -d postgres -c "SELECT 1 FROM pg_database WHERE datname='guppi'"
    if ($hasDb -ne '1') {
        Run "$PgBin\psql.exe" ($psql + @('-d', 'postgres', '-c',
            "CREATE ROLE guppi LOGIN PASSWORD '$($secret.guppi)'")) 'creating the guppi role'
        Run "$PgBin\psql.exe" ($psql + @('-d', 'postgres', '-c', 'CREATE DATABASE guppi OWNER guppi')) 'creating the database'
    }
    $env:PGOPTIONS = '-c client_min_messages=warning'
    Run "$PgBin\psql.exe" ($psql + @('-d', 'guppi', '-f', "$Agent\infrastructure\schema\core.sql",
                                     '-f', "$Agent\infrastructure\schema\local.sql")) 'applying the schema'
    Remove-Item Env:\PGOPTIONS
    Run "$PgBin\psql.exe" ($psql + @('-d', 'guppi', '-c', @"
ALTER DATABASE guppi SET synchronous_commit = off;
GRANT ALL ON SCHEMA public TO guppi;
GRANT ALL ON ALL TABLES IN SCHEMA public TO guppi;
ALTER ROLE guppi PASSWORD '$($secret.guppi)';
ALTER ROLE guppi_authenticator PASSWORD '$($secret.authenticator)';
"@)) 'granting the hub its tables'
} finally {
    & "$PgBin\pg_ctl.exe" -D $PgData -m fast -w stop | Out-Null
    Remove-Item Env:\PGPASSWORD
}

# ── 6. Configuration and commands ────────────────────────────────────────────
Step '6/7 Configuration and commands'
# Read by guppi-hub (guppi_cli/hub.py) for where everything is, and by the agent.
@"
# Guppi hub. Local mode is an explicit opt-in (never inferred).
GUPPI_BACKEND="local"
DATABASE_URL="postgresql://guppi:$($secret.guppi)@127.0.0.1:$PgPort/guppi"
GUPPI_DATA_DIR="$Data"
GUPPI_UI_DIR="$Root\ui"
GUPPI_NATS_SERVER="$Bin\nats-server.exe"
GUPPI_NATS_CONF="$Agent\infrastructure\nats\nats.dev.conf"
GUPPI_POSTGREST="$Bin\postgrest.exe"
GUPPI_POSTGREST_CONF="$Etc\postgrest.conf"
GUPPI_AGENT_DIR="$Agent"
GUPPI_AGENT_PYTHON="$Agent\.venv\Scripts\python.exe"
GUPPI_PG_BIN="$PgBin"
GUPPI_PG_DATA="$PgData"
GUPPI_PG_PORT="$PgPort"
"@ | ForEach-Object { WriteText "$Etc\hub.env" $_ }

@"
db-uri = "postgres://guppi_authenticator:$($secret.authenticator)@127.0.0.1:$PgPort/guppi"
db-schemas = "public"
db-anon-role = "web_anon"
server-host = "0.0.0.0"
server-port = 3010
db-max-rows = 10000
db-pool = 8
db-pool-acquisition-timeout = 10
"@ | ForEach-Object { WriteText "$Etc\postgrest.conf" $_ }

# The rack's settings, as on Linux: ~/.guppi. Seeded once, never overwritten.
if (-not (Test-Path "$RackHome\rig_config.yml") -and (Test-Path "$Rack\rig_config.yml")) {
    Copy-Item "$Rack\rig_config.yml" "$RackHome\rig_config.yml"
}

# Paths in the .cmd shims are relative to the shim (%~dp0) or come from the
# environment, never spelled out: cmd.exe reads a batch file in the console's
# code page, which would garble a non-ASCII user name.
WriteText "$Bin\guppi-hub.cmd" @"
@echo off
"%~dp0..\src\packages\cli\.venv\Scripts\python.exe" -m guppi_cli.hub "%~dp0..\etc\hub.env"
"@
# The rack falls back to a rig_config.yml in its working directory, which is
# the release tree: pin the operator's instead. Source tree or bytecode build.
WriteText "$Bin\guppi-rack.cmd" @"
@echo off
if not defined RIG_CONFIG_PATH set "RIG_CONFIG_PATH=%USERPROFILE%\.guppi\rig_config.yml"
cd /d "%~dp0..\src\packages\rack"
set "MAIN=src\main.py"
if not exist "%MAIN%" set "MAIN=src\main.pyc"
".venv\Scripts\python.exe" "%MAIN%" %*
"@
# guppi itself is an .exe, not a shim: a batch file asks "Terminate batch job
# (Y/N)?" after every Ctrl-C. A venv's console script embeds its interpreter's
# absolute path, so a copy runs from bin\ without the venv's python.exe on PATH.
Copy-Item -Force "$Cli\.venv\Scripts\guppi.exe" "$Bin\guppi.exe"
& "$Bin\guppi.exe" --help *> $null
if ($LASTEXITCODE -ne 0) {
    Note 'the copied guppi.exe does not run: using a shim instead'
    Remove-Item "$Bin\guppi.exe"
    WriteText "$Bin\guppi.cmd" "@echo off`r`n`"%~dp0..\src\packages\cli\.venv\Scripts\guppi.exe`" %*`r`n"
}
UserPath $Bin $true

# ── 7. Check it starts ───────────────────────────────────────────────────────
Step '7/7 Starting the hub once to check it answers'
$hub = Start-Process -PassThru -WindowStyle Hidden -FilePath "$Cli\.venv\Scripts\python.exe" `
    -ArgumentList @('-m', 'guppi_cli.hub', "`"$Etc\hub.env`"") `
    -RedirectStandardOutput "$Tmp\hub.out" -RedirectStandardError "$Tmp\hub.err"
$ok = $false
for ($i = 0; $i -lt 60 -and -not $hub.HasExited; $i++) {
    if (HubAnswers) { $ok = $true; break }
    Start-Sleep -Seconds 1
}
# The supervisor's servers are in Job Objects that close with it: killing it stops them all.
if (-not $hub.HasExited) { & taskkill.exe /PID $hub.Id /T /F | Out-Null }
$hub.WaitForExit()
& "$PgBin\pg_ctl.exe" -D $PgData -m fast -w stop 2>$null | Out-Null  # if a hard kill left it

if (-not $ok) {
    Get-Content "$Tmp\hub.out", "$Tmp\hub.err" -Tail 25 -ErrorAction SilentlyContinue | Write-Host
    if ($upgrading -and (Test-Path "$Root\src.prev")) {
        Remove-Item -Recurse -Force "$Root\src", "$Root\ui" -ErrorAction SilentlyContinue
        Move-Item "$Root\src.prev" "$Root\src"
        if (Test-Path "$Root\ui.prev") { Move-Item "$Root\ui.prev" "$Root\ui" }
        Copy-Item -Force "$Cli\.venv\Scripts\guppi.exe" "$Bin\guppi.exe"
        Fail "the upgraded hub didn't start, so the previous version ($prevRef) is back. Its log is above."
    }
    Fail "the hub didn't answer on :8000 within 60 s. Its log is above."
}
Remove-Item -Recurse -Force "$Root\src.prev", "$Root\ui.prev" -ErrorAction SilentlyContinue
Set-Content -Encoding ascii "$Etc\version" $Ref

} finally {
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Guppi $Ref is installed." -ForegroundColor Green
Write-Host '  Open a NEW terminal (so it sees the updated PATH), then:'
Write-Host '    guppi up        start the bench (hub + rack); Ctrl-C stops it'
Write-Host '    guppi hub       or just the hub;  guppi rack  just the rack'
Write-Host '  Dashboard: http://localhost:8000 while it runs.'
Write-Host "  Instruments are set up in $RackHome\rig_config.yml (or from the dashboard)."
