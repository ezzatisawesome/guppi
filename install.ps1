#Requires -Version 5.1
<#
Guppi bench installer for Windows: the hub and the rack, for you, without
administrator rights.

    irm https://github.com/ezzatisawesome/guppi/releases/latest/download/install.ps1 | iex

Everything lands in %LOCALAPPDATA%\Guppi and your user PATH; nothing is
installed system-wide and nothing runs as a service. Run `guppi up` to start
the bench (Ctrl-C stops it), or `guppi hub` / `guppi rack` on their own. The
rack's settings live in %USERPROFILE%\.guppi, as on Linux.

    src\        the release (hub, rack, CLI) and their Python environments
    pgsql\      a private PostgreSQL, on 127.0.0.1 only, password-protected
    postgrest\  PostgREST, beside the PostgreSQL client DLLs it loads
    bin\        guppi, guppi-hub, guppi-rack, nats-server, uv
    etc\        hub.env (where everything is), postgrest.conf, db.secret
    data\       the database cluster, NATS's store, run artifacts

Re-running upgrades in place (stop the bench first); a failed upgrade rolls
back. Options: -Ref <tag>, -SrcTarball <path> (offline), -Uninstall [-Purge],
-Network (let other computers on your network open the dashboard, and a rack on
another computer link to this hub; Windows then asks once to let Guppi through
its firewall), -LocalOnly (back to this PC only: a linked remote rack drops off).
`iex` passes none, so to give one, run the script as a script block:

    & ([scriptblock]::Create((irm <the URL above>))) -Uninstall

The hub needs ports 8000, 4222, 9222, 3010 and 55432: if another program
holds one, the installer names it and stops before changing anything. The
rack needs 8080 (RACK_PORT moves it), which only gets a warning here. Every one
listens on this PC only (127.0.0.1) unless the bench was installed with
-Network, so a first install raises no firewall prompt.

Just the guppi command (a laptop that drives a bench from elsewhere), no bench:

    & ([scriptblock]::Create((irm https://github.com/ezzatisawesome/guppi/releases/latest/download/install.ps1))) -Cli

or set $env:GUPPI_CLI = '1' before the irm | iex line.

Windows on ARM runs the x64 build under emulation: several of the hub's
Python dependencies have no ARM64 wheels.
#>
param(
    [string]$Ref = $env:GUPPI_REF,
    [string]$SrcTarball = $env:GUPPI_SRC_TARBALL,
    [string]$UiTarball = $env:GUPPI_UI_TARBALL,
    [switch]$Uninstall,
    [switch]$Purge,
    [switch]$Cli,
    [switch]$Network,
    [switch]$LocalOnly
)
# `irm ... | iex` runs a script in the caller's own scope, so the install runs
# in a child one: its preferences, its helpers and the database passwords it
# reads end with it, instead of staying behind in the user's PowerShell.
& {
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # the progress bar makes downloads 10x slower
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo = 'ezzatisawesome/guppi'
# Windows' own tar (bsdtar): a Git for Windows or MSYS tar earlier on PATH
# reads "C:\..." as a remote host and the extract fails.
$Tar = Join-Path $env:SystemRoot 'System32\tar.exe'
if (-not (Test-Path $Tar)) { $Tar = 'tar.exe' }
$Root = Join-Path $env:LOCALAPPDATA 'Guppi'
$Bin, $Etc, $Data = "$Root\bin", "$Root\etc", "$Root\data"
$PgDist, $PgData = "$Root\pgsql", "$Root\data\pg"
$Pgrst = "$Root\postgrest"
$RackHome = Join-Path $env:USERPROFILE '.guppi'
# A cluster's data directory belongs to one Postgres major, so an existing
# install keeps the binaries it was created with; only a new one gets these.
$PgVersion = '18.6.1'
$PgPort = 55432  # off 5432, so a Postgres already on this machine is left alone
# What listens where: the hub's must be free to finish (step 7 starts it once).
$HubPorts = @{ 8000 = 'the hub'; 4222 = 'NATS'; 9222 = 'NATS for browsers'; 3010 = 'PostgREST'; $PgPort = 'PostgreSQL' }
$RackPort = if ($env:RACK_PORT -match '^\d+$') { [int]$env:RACK_PORT } else { 8080 }
# Pinned fallbacks for when the GitHub API rate-limits us (60/hour per IP).
$NatsFallback, $PostgrestFallback, $UvFallback = 'v2.15.2', 'v16.5', '0.13.7'
$PostgrestSha256 = '17f595b0d8dd37473d0231417dea07c5ac9f791282ff5b017fae51ff29e5de2f'  # v16.5 windows-x86-64
# Environment variables are the process's, not the scope's, and under `iex` the
# process is the user's PowerShell: the ones set below are put back at the end.
$SavedEnv = @{}
foreach ($name in 'UV_PYTHON', 'UV_PYTHON_PREFERENCE', 'UV_PYTHON_INSTALL_DIR', 'UV_CACHE_DIR', 'UV_SYSTEM_CERTS', 'UV_NATIVE_TLS',
                  'HTTP_PROXY', 'HTTPS_PROXY', 'PGPASSWORD', 'PGOPTIONS') {
    $SavedEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
# One interpreter for every venv, x64 everywhere (see above).
$env:UV_PYTHON = 'cpython-3.12-windows-x86_64-none'
$env:UV_PYTHON_INSTALL_DIR = "$Root\python"
# Only a Python uv downloaded into the bench's own folder: never one another
# program registered (PEP 514). A Python that belongs to someone else's tools
# leaves the bench broken the day that program moves or removes it (a dev
# toolchain's 3.12 registered under HKCU, say).
$env:UV_PYTHON_PREFERENCE = 'only-managed'
$env:UV_CACHE_DIR = "$Root\cache\uv"
# A company network that inspects TLS re-signs every site with its own root CA,
# which Windows trusts and PowerShell's downloads (steps 1-3) use. uv trusts only
# the roots it ships unless told otherwise, so step 4 failed there on a
# certificate error. UV_NATIVE_TLS is the same switch for a uv older than 0.11
# (-Cli uses one already on PATH); a newer uv ignores it when this is set.
$env:UV_SYSTEM_CERTS = 'true'
$env:UV_NATIVE_TLS = 'true'

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
function Warn([string]$msg) { Write-Host "!  $msg" -ForegroundColor Yellow }

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

# Verify a release asset against the release's SHA256SUMS. Fails CLOSED: no
# SHA256SUMS, or no line for the asset, is a refusal, not a skip.
# GUPPI_SKIP_VERIFY=1 is the escape hatch for dev builds, and says so loudly.
function VerifyRelease([string]$file, [string]$name) {
    if ($env:GUPPI_SKIP_VERIFY -eq '1') { Warn "GUPPI_SKIP_VERIFY=1: $name is NOT being verified. Dev builds only."; return }
    $sum = SumFor "$Tmp\SHA256SUMS" $name
    if (-not $sum) { Fail "no checksum for $name on release $Ref (no SHA256SUMS, or $name isn't in it): refusing to install unverified code. (Dev builds only: GUPPI_SKIP_VERIFY=1 skips this check.)" }
    Verify $file $sum
    Note "${name}: checksum OK"
}

function HubAnswers {
    try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 'http://127.0.0.1:8000/' | Out-Null; return $true }
    catch { return [bool]$_.Exception.Response }  # an HTTP error still means something answered
}

# This install's own programs (the hub's servers, the rack, a guppi command),
# known by where they run from: Windows won't replace or delete a file that one
# has open. Anything else on the machine is not ours to stop.
function OwnProcesses {
    @(Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith("$Root\", [StringComparison]::OrdinalIgnoreCase) })
}

function RefuseWhileRunning([string]$then) {
    # `guppi update` and `guppi uninstall` start this as they exit, and a venv's
    # python.exe is a launcher that outlives its child a moment: let them go.
    for ($i = 0; ($running = OwnProcesses) -and $i -lt 5; $i++) { Start-Sleep -Milliseconds 400 }
    # A database a killed hub left behind is the hub's alone: stop it, as guppi hub does.
    if ($running -and -not @($running | Where-Object ProcessName -ne 'postgres')) {
        Note 'stopping the database an earlier hub left running'
        $null = Quietly "$PgDist\bin\pg_ctl.exe" @('-D', $PgData, '-m', 'fast', '-w', 'stop')
        $running = OwnProcesses
    }
    if ($running) {
        $names = @($running | ForEach-Object ProcessName | Sort-Object -Unique) -join ', '
        Fail "Guppi is running ($names): stop it (Ctrl-C where guppi up or guppi hub runs), then $then."
    }
}

# One line per port in $ports (port -> what of ours needs it) that some program
# listens on, naming the program, so a clash says what to stop.
function PortsInUse([hashtable]$ports) {
    if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) { return }
    Get-NetTCPConnection -State Listen -LocalPort @($ports.Keys) -ErrorAction SilentlyContinue |
        Sort-Object LocalPort, OwningProcess -Unique | ForEach-Object {
            $p = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
            $who = if ($p.Path) { "$($p.ProcessName) (pid $($p.Id), $($p.Path))" }
                   elseif ($p) { "$($p.ProcessName) (pid $($p.Id))" }
                   else { "pid $($_.OwningProcess)" }
            "port $($_.LocalPort) ($($ports[[int]$_.LocalPort])) is in use by $who"
        }
}

# The proxy Windows gives $url, as "http://host:port"; $null for a direct
# connection, or when it can't be worked out.
function SystemProxy([string]$url) {
    try {
        $uri = [Uri]$url
        $proxy = [Net.WebRequest]::GetSystemWebProxy().GetProxy($uri)
        if ($proxy -and $proxy.Authority -ne $uri.Authority) { return "$($proxy.Scheme)://$($proxy.Authority)" }
    } catch { }
    return $null
}

# uv reads a fixed proxy from the registry but never a PAC script, which is how
# many company networks hand one out: there its downloads went direct and failed
# while PowerShell's went through. For the uv steps only (the hub inherits none
# of it), hand uv the proxy Windows resolves, unless the user named one.
function UseWindowsProxyForUv {
    if ($env:HTTPS_PROXY -or $env:ALL_PROXY) { return }
    $proxy = SystemProxy 'https://files.pythonhosted.org/'
    if ($proxy) {
        $env:HTTPS_PROXY, $env:HTTP_PROXY = $proxy, $proxy
        Note "uv downloads through Windows' proxy, $proxy"
    }
}

# Put back what the user's session had for these (see $SavedEnv).
function RestoreEnv([string[]]$names) {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $SavedEnv[$name], 'Process') }
}

# Rename a folder of ours, waiting out a moment's lock: Windows refuses while
# any program has a file open inside it, and an antivirus scan of a fresh tree
# or Explorer showing it is enough. Fails with what to close, not a raw
# "Access to the path is denied". One rename, whole or not at all: Move-Item
# moved what it could and left the held file behind (windows-install CI,
# 2026-11-24), and a half src.prev then passed for the last good tree.
function MoveDir([string]$from, [string]$to) {
    for ($i = 1; $i -le 10; $i++) {
        try { [IO.Directory]::Move($from, $to); return }
        catch { if ($i -eq 10) { break } ; Start-Sleep -Milliseconds 500 }
    }
    Fail "couldn't move $from (a program has a file open in it: an Explorer window, a terminal whose folder is in it, an editor, antivirus). Close it, then re-run the installer."
}

# Put the last good release back after a failed upgrade: the half-built tree is
# what bin\guppi.exe runs from, so leaving it there broke guppi itself, and with
# it the `guppi update` that would have fixed things. $true once it is back.
function RestorePrevious {
    if (-not (Test-Path "$Root\src.prev")) { return $false }
    Remove-Item -Recurse -Force "$Root\src", "$Root\ui" -ErrorAction SilentlyContinue
    if (Test-Path "$Root\src") { return $false }  # still held open: the next run recovers it
    [IO.Directory]::Move("$Root\src.prev", "$Root\src")
    if (Test-Path "$Root\ui.prev") { [IO.Directory]::Move("$Root\ui.prev", "$Root\ui") }
    $exe = "$Root\src\packages\cli\.venv\Scripts\guppi.exe"
    if (Test-Path $exe) { Copy-Item -Force $exe "$Bin\guppi.exe" -ErrorAction SilentlyContinue }
    return $true
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

# A native command whose chatter a customer doesn't need (initdb ends "Success.
# You can now start the database server using: pg_ctl ..."): its output is
# shown only when it fails. Not for anything that leaves a process running.
function RunHushed([string]$exe, [string[]]$argv, [string]$what) {
    $ErrorActionPreference = 'Continue'  # 5.1 turns each stderr line into an error record
    $out = @(& $exe @argv 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
        $out | ForEach-Object { Write-Host "   $_" }
        Fail "$what failed (exit $LASTEXITCODE)"
    }
}

# A native command that leaves a server running (pg_ctl start), run without
# handing it a pipe. Under a capture (`irm ... | iex *>&1 | Tee-Object log`)
# PowerShell reads a native command's output through a pipe until it closes;
# the postgres pg_ctl starts inherits that pipe and keeps it open, so the
# install stalls after "server started" with no message. Started this way it
# shares the console and nothing waits on it.
function RunDetached([string]$exe, [string[]]$argv, [string]$what) {
    $psi = New-Object Diagnostics.ProcessStartInfo $exe
    $psi.Arguments = @($argv | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $psi.UseShellExecute = $false
    $p = [Diagnostics.Process]::Start($psi)
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { Fail "$what failed (exit $($p.ExitCode))" }
}

# A native command's exit code, its output discarded. Windows PowerShell turns
# each line on a redirected stderr into an error record, which 'Stop' throws:
# here stderr is expected (pg_ctl stopping nothing, a guppi.exe that won't run)
# and only the exit code counts.
function Quietly([string]$exe, [string[]]$argv) {
    $ErrorActionPreference = 'Continue'
    try { & $exe @argv *> $null } catch { return 1 }  # it didn't even start
    return $LASTEXITCODE
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

# ── CLI only ─────────────────────────────────────────────────────────────────
# Just `guppi`, for this user: uv brings Python 3.12 (the release is 3.12
# bytecode) and `uv tool install` gives guppi its own environment and a command
# on PATH. Nothing lands in the bench's folder. Re-running (or `guppi update` on
# such a machine) upgrades in place.
if ($Cli -or $env:GUPPI_CLI -eq '1') {
    if (Test-Path "$Root\src\packages\cli") { Fail 'this machine has a Guppi bench, which already has guppi: update it with guppi update' }
    # uv's own defaults, not the bench's private Python and cache.
    Remove-Item Env:UV_PYTHON_INSTALL_DIR, Env:UV_CACHE_DIR, Env:UV_PYTHON_PREFERENCE -ErrorAction SilentlyContinue
    $Tmp = Join-Path ([IO.Path]::GetTempPath()) ("guppi-cli-" + [guid]::NewGuid())
    New-Item -ItemType Directory $Tmp | Out-Null
    try {
        $uv = (Get-Command uv.exe -ErrorAction SilentlyContinue).Source
        if (-not $uv) {
            Step 'uv (it manages guppi''s Python)'
            $uvTag = LatestTag 'astral-sh/uv' $UvFallback
            $uvZip = 'uv-x86_64-pc-windows-msvc.zip'
            Fetch "https://github.com/astral-sh/uv/releases/download/$uvTag/$uvZip" "$Tmp\uv.zip"
            Fetch "https://github.com/astral-sh/uv/releases/download/$uvTag/$uvZip.sha256" "$Tmp\uv.sha256"
            Verify "$Tmp\uv.zip" ((Get-Content "$Tmp\uv.sha256") -split '\s+')[0]
            Expand-Archive -Force "$Tmp\uv.zip" "$Tmp\uv"
            $uvHome = Join-Path $env:USERPROFILE '.local\bin'
            New-Item -ItemType Directory -Force $uvHome | Out-Null
            Copy-Item -Force "$Tmp\uv\uv.exe", "$Tmp\uv\uvx.exe" $uvHome -ErrorAction SilentlyContinue
            $uv = "$uvHome\uv.exe"
            if (-not (Test-Path $uv)) { Fail "uv didn't land at $uv" }
            UserPath $uvHome $true
        }
        if ($SrcTarball) {
            if (-not $Ref) { $Ref = 'local' }
            Copy-Item $SrcTarball "$Tmp\guppi-src.tar.gz"
        } else {
            if (-not $Ref) { $Ref = LatestTag $Repo '' }
            Step "guppi $Ref"
            $dl = "https://github.com/$Repo/releases/download/$Ref"
            try { Fetch "$dl/SHA256SUMS" "$Tmp\SHA256SUMS" } catch { }  # missing: VerifyRelease refuses
            Fetch "$dl/guppi-src.tar.gz" "$Tmp\guppi-src.tar.gz"
            VerifyRelease "$Tmp\guppi-src.tar.gz" 'guppi-src.tar.gz'
        }
        New-Item -ItemType Directory "$Tmp\src" | Out-Null
        Run $Tar @('-xzf', "$Tmp\guppi-src.tar.gz", '-C', "$Tmp\src", '--strip-components=1') 'extracting the release'
        Step 'the guppi CLI'
        UseWindowsProxyForUv
        # With the [preview] extra (guppi preview --png); without it if that can't install here.
        # Quietly: uv's progress lines on stderr would end the install under 'Stop'.
        if ((Quietly $uv @('tool', 'install', '--force', '--python', '3.12', "$Tmp\src\packages\cli[preview]")) -ne 0) {
            Run $uv @('tool', 'install', '--force', '--python', '3.12', "$Tmp\src\packages\cli") 'uv tool install'
            Write-Host '  (installed without PNG preview: its engine did not install here; guppi preview draws text)'
        }
        $toolBin = (& $uv tool dir --bin).Trim()
        RestoreEnv 'HTTP_PROXY', 'HTTPS_PROXY'
        Run "$toolBin\guppi.exe" @('--help') 'guppi --help' | Out-Null
        UserPath $toolBin $true
        Write-Host "OK  guppi $Ref installed: $toolBin\guppi.exe" -ForegroundColor Green
        Note 'Open a new terminal, then: guppi use <bench hostname or IP>   (or: guppi use cloud; guppi login)'
        Note 'Update later with: guppi update'
    } finally {
        Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
    }
    return
}

# ── Uninstall ────────────────────────────────────────────────────────────────
if ($Uninstall) {
    RefuseWhileRunning 'uninstall again'
    # What this installer made, by name: a folder called Guppi may hold someone else's files too.
    $ours = @('src', 'src.prev', 'ui', 'ui.prev', 'bin', 'postgrest', 'python', 'cache', 'pgsql')
    if ($Purge) { $ours += 'etc', 'data' }
    foreach ($d in $ours) { Remove-Item -Recurse -Force "$Root\$d" -ErrorAction SilentlyContinue }
    if (-not $Purge) {
        # Kept data keeps only the one file that opens it (db.secret). The rest
        # of etc\ is rewritten by a reinstall, and hub.env and postgrest.conf
        # carry the database passwords in plain text; a kept version would make
        # a later CLI-only install report this release.
        foreach ($f in @('hub.env', 'postgrest.conf', 'version')) {
            Remove-Item -Force "$Etc\$f" -ErrorAction SilentlyContinue
        }
    }
    $stuck = @($ours | Where-Object { Test-Path "$Root\$_" })
    if ($stuck) {
        Fail "couldn't delete $(($stuck | ForEach-Object { "$Root\$_" }) -join ', '): close whatever has files open there, then uninstall again."
    }
    UserPath $Bin $false
    if (-not $Purge) {
        Write-Host 'Uninstalled.'
    } elseif ($others = @(Get-ChildItem -Force $Root -ErrorAction SilentlyContinue)) {
        Write-Host "Uninstalled, and deleted the database and settings in $Root."
        Note "$Root itself stays: it also holds files Guppi didn't put there ($(($others | Select-Object -First 3 -ExpandProperty Name) -join ', '))."
    } else {
        Remove-Item -Force $Root -ErrorAction SilentlyContinue
        Write-Host "Uninstalled, and deleted the database and settings in $Root."
    }
    # Say everything that stays, by name (dashboards, firewall rules), with one
    # spelling of purge, one a PowerShell user can paste.
    $workspace = if ($env:GUPPI_WORKSPACE_PATH) { $env:GUPPI_WORKSPACE_PATH } else { "$env:USERPROFILE\guppi-workspace" }
    $kept = @(@(
        $(if (-not $Purge) { "the database ($Data) and the password file that opens it ($Etc\db.secret)" }),
        $(if (Test-Path $RackHome) { "the rig settings ($RackHome)" }),
        $(if (Test-Path $workspace) { "your dashboards and data views ($workspace)" })
    ) | Where-Object { $_ })
    if ($kept) { Write-Host "Kept: $($kept -join ', ')." }
    Note 'Windows Firewall may still list nats-server and postgrest if its prompt was answered: remove them under Windows Security > Firewall & network protection > Allow an app through firewall.'
    if (-not $Purge) {
        # `guppi` is gone now: the installer itself is what deletes the rest.
        Write-Host 'To delete the database too, paste:'
        Write-Host '  & ([scriptblock]::Create((irm https://github.com/ezzatisawesome/guppi/releases/latest/download/install.ps1))) -Uninstall -Purge'
    }
    return
}

# ── Preflight ────────────────────────────────────────────────────────────────
if (-not (Get-Command $Tar -ErrorAction SilentlyContinue)) {
    Fail 'tar.exe is missing: Guppi needs Windows 10 version 1803 or later.'
}
if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
    Note 'Windows on ARM: installing the x64 build, which runs under emulation.'
}
RefuseWhileRunning 're-run the installer'
# Anything else answering on :8000 is not "the hub is running": say what it is.
$busy = @(PortsInUse $HubPorts)
if ($busy) {
    $busy | ForEach-Object { Note $_ }
    Fail 'another program has ports the hub needs (above): stop it, then re-run the installer.'
}
foreach ($line in @(PortsInUse @{ $RackPort = 'the rack' })) {
    Warn "$line. guppi up needs it too: stop that program first, or set RACK_PORT to a free port."
}

New-Item -ItemType Directory -Force $Root, $Bin, $Pgrst, $Etc, $Data, "$Data\artifacts", $RackHome | Out-Null
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
    try { Fetch "$dl/SHA256SUMS" "$Tmp\SHA256SUMS" } catch { }  # missing: VerifyRelease refuses
    Fetch "$dl/guppi-src.tar.gz" "$Tmp\guppi-src.tar.gz"
    VerifyRelease "$Tmp\guppi-src.tar.gz" 'guppi-src.tar.gz'
    if (-not $UiTarball) {
        $haveUi = $true
        try { Fetch "$dl/guppi-ui-local.tar.gz" "$Tmp\guppi-ui-local.tar.gz" }
        catch { $haveUi = $false; Note 'no UI bundle on this release: the hub runs API-only' }
        if ($haveUi) {
            VerifyRelease "$Tmp\guppi-ui-local.tar.gz" 'guppi-ui-local.tar.gz'
            $UiTarball = "$Tmp\guppi-ui-local.tar.gz"
        }
    }
}

$upgrading = Test-Path "$Root\src"
# Only a finished install (it wrote etc\version last) is worth rolling back to:
# after one that stopped part-way, src.prev is half a tree.
$canRollBack = $upgrading -and (Test-Path "$Etc\version")
if ($upgrading) {
    $prevRef = if (Test-Path "$Etc\version") { Get-Content "$Etc\version" } else { 'the last install' }
    if (Test-Path "$Etc\version") { Note "upgrading from $prevRef" }
    else { Note 'finishing an earlier install that stopped part-way' }
    if (Test-Path "$Root\src.prev") {
        Note '(recovering from an interrupted update: keeping the last good tree)'
        Remove-Item -Recurse -Force "$Root\src", "$Root\ui" -ErrorAction SilentlyContinue
    } elseif ($canRollBack) {
        MoveDir "$Root\src" "$Root\src.prev"
        if (Test-Path "$Root\ui") { MoveDir "$Root\ui" "$Root\ui.prev" }
    } else {
        # Half a tree from a run that stopped: nothing in it to go back to.
        Remove-Item -Recurse -Force "$Root\src", "$Root\ui" -ErrorAction SilentlyContinue
    }
}
New-Item -ItemType Directory -Force "$Root\src", "$Root\ui" | Out-Null
Run $Tar @('-xzf', "$Tmp\guppi-src.tar.gz", '-C', "$Root\src", '--strip-components=1') 'extracting the release'
if ($UiTarball) { Run $Tar @('-xzf', $UiTarball, '-C', "$Root\ui") 'extracting the UI' }
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

# PostgREST publishes no checksums, so it's pinned: this version, checked against
# this hash (GitHub's asset digest, matched against the downloaded file). Bump both
# together.
$pgrstTag = $PostgrestFallback
Fetch "https://github.com/PostgREST/postgrest/releases/download/$pgrstTag/postgrest-$pgrstTag-windows-x86-64.zip" "$Tmp\postgrest.zip"
Verify "$Tmp\postgrest.zip" $PostgrestSha256
Expand-Archive -Force "$Tmp\postgrest.zip" "$Tmp\postgrest"
Copy-Item -Force "$Tmp\postgrest\postgrest.exe" "$Pgrst\postgrest.exe"
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

# PostgREST's Windows build loads PostgreSQL's client library (libpq.dll and
# whatever it loads), which its zip leaves out. Windows looks first beside the
# program, so PostgreSQL's DLLs go there, all of them so a new PostgreSQL build
# can't add a dependency we didn't list, and on every run so they match the
# PostgreSQL this install keeps. Not into bin\: that's on PATH, where other
# programs would pick them up.
Copy-Item -Force "$PgBin\*.dll" $Pgrst
$rc = Quietly "$Pgrst\postgrest.exe" @('--version')
if ($rc -eq -1073741515) {  # 0xC0000135, STATUS_DLL_NOT_FOUND
    Fail "PostgREST can't start: Windows can't find a DLL it needs in $Pgrst. Please report this, with this screen: https://github.com/$Repo/issues"
} elseif ($rc -ne 0) {
    Fail "PostgREST can't start (exit code $rc). See what it says: & `"$Pgrst\postgrest.exe`" --version"
}

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
    RunHushed "$PgBin\initdb.exe" @('-D', $PgData, '-U', 'postgres', "--pwfile=$pw", '-E', 'UTF8',
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
UseWindowsProxyForUv
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
RestoreEnv 'HTTP_PROXY', 'HTTPS_PROXY'  # the hub, started at step 7, gets the session's own

# ── 5. Database: roles, schema ───────────────────────────────────────────────
Step '5/7 Database'
$env:PGPASSWORD = $secret.postgres
RunDetached "$PgBin\pg_ctl.exe" @('-D', $PgData, '-l', "$Data\pg-install.log", '-w', '-s', 'start') "starting PostgreSQL (its log: $Data\pg-install.log)"
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
# Who can open the dashboard: this PC only, unless asked. Listening on the
# network made Windows ask about the firewall in the middle of a first install
# ("Publisher Unknown"), and an unanswered prompt left Block rules while guppi
# up still printed a network address; NATS is
# anonymous, so on the network anyone there could reach the bench's broker.
# -Network opens it to other computers, -LocalOnly closes it again; a re-run
# keeps the last choice, and a bench installed before this choice existed
# (no GUPPI_HUB_HOST in hub.env) keeps serving the network as it did.
$HubHost = '127.0.0.1'
if ($Network) { $HubHost = '0.0.0.0' }
elseif (-not $LocalOnly -and (Test-Path "$Etc\hub.env")) {
    $was = Select-String -Path "$Etc\hub.env" -Pattern '^GUPPI_HUB_HOST="?([^"]*)"?' | Select-Object -First 1
    $HubHost = if ($was) { $was.Matches[0].Groups[1].Value } else { '0.0.0.0' }
    if ($HubHost -notin @('127.0.0.1', '0.0.0.0')) { $HubHost = '127.0.0.1' }
}
$Shared = $HubHost -eq '0.0.0.0'
# The broker's own settings, with where it listens: the agent's dev config
# (packages/agent/infrastructure/nats/nats.dev.conf) binds every interface.
@"
# NATS for this bench, written by the installer. Listens on $HubHost
# (re-run the installer with -Network or -LocalOnly to change it).
host: $HubHost
port: 4222

websocket {
  host: $HubHost
  port: 9222
  no_tls: true
}

jetstream {
  store_dir: ".nats-data"
}
"@ | ForEach-Object { WriteText "$Etc\nats.conf" $_ }
# Read by guppi-hub (guppi_cli/hub.py) for where everything is, and by the agent.
@"
# Guppi hub. Local mode is an explicit opt-in (never inferred).
GUPPI_BACKEND="local"
DATABASE_URL="postgresql://guppi:$($secret.guppi)@127.0.0.1:$PgPort/guppi"
GUPPI_DATA_DIR="$Data"
GUPPI_UI_DIR="$Root\ui"
GUPPI_HUB_HOST="$HubHost"
NATS_URL="nats://127.0.0.1:4222"
GUPPI_NATS_SERVER="$Bin\nats-server.exe"
GUPPI_NATS_CONF="$Etc\nats.conf"
GUPPI_POSTGREST="$Pgrst\postgrest.exe"
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
server-host = "$HubHost"
server-port = 3010
db-max-rows = 10000
db-pool = 8
db-pool-acquisition-timeout = 10
"@ | ForEach-Object { WriteText "$Etc\postgrest.conf" $_ }

# The rack's settings, as on Linux: ~/.guppi. Seeded once, never overwritten.
if (-not (Test-Path "$RackHome\rig_config.yml") -and (Test-Path "$Rack\rig_config.yml")) {
    Copy-Item "$Rack\rig_config.yml" "$RackHome\rig_config.yml"
}

# The .cmd shims only point at guppi: how the hub and the rack start (their
# interpreter, folder and defaults) is written once, in the CLI
# (guppi_cli/host/install.py windows_launch), which `guppi up` uses too. A
# relative path (%~dp0), so a non-ASCII user name isn't garbled by cmd.exe's
# code page; `guppi` is guppi.exe, or the guppi.cmd fallback below.
foreach ($svc in 'guppi-hub', 'guppi-rack') {
    WriteText "$Bin\$svc.cmd" "@echo off`r`n`"%~dp0guppi`" _service $svc %*`r`n"
}
# guppi itself is an .exe, not a shim: a batch file asks "Terminate batch job
# (Y/N)?" after every Ctrl-C. A venv's console script embeds its interpreter's
# absolute path, so a copy runs from bin\ without the venv's python.exe on PATH.
Copy-Item -Force "$Cli\.venv\Scripts\guppi.exe" "$Bin\guppi.exe"
if ((Quietly "$Bin\guppi.exe" @('--help')) -ne 0) {
    Note 'the copied guppi.exe does not run: using a shim instead'
    Remove-Item "$Bin\guppi.exe"
    WriteText "$Bin\guppi.cmd" "@echo off`r`n`"%~dp0..\src\packages\cli\.venv\Scripts\guppi.exe`" %*`r`n"
}
UserPath $Bin $true

# ── 7. Check it starts ───────────────────────────────────────────────────────
Step '7/7 Starting the hub once to check it answers'
if ($Shared) {
    # Asked for with -Network: Windows asks the first time the hub listens on the
    # network. Current Windows 11 asks one question covering every network
    # (docs/public/getting-started.md says when to choose which).
    Note 'Windows will ask to let python, nats-server and postgrest through its firewall.'
    Note 'Allow lets other computers on this network open the dashboard; Guppi has no login'
    Note 'there, so allow it only on a PC that stays on your bench network. Cancel keeps it to this PC.'
}
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
$null = Quietly "$PgBin\pg_ctl.exe" @('-D', $PgData, '-m', 'fast', '-w', 'stop')  # if a hard kill left it

if (-not $ok) {
    Get-Content "$Tmp\hub.out", "$Tmp\hub.err" -Tail 25 -ErrorAction SilentlyContinue | Write-Host
    if ($canRollBack -and (RestorePrevious)) {
        Fail "the upgraded hub didn't start, so the previous version ($prevRef) is back. Its log is above."
    }
    Fail "the hub didn't answer on :8000 within 60 s. Its log is above."
}
Remove-Item -Recurse -Force "$Root\src.prev", "$Root\ui.prev" -ErrorAction SilentlyContinue
# Where earlier releases put PostgREST, without its DLLs. Only now: until the
# hub.env above, a rolled-back or half-done upgrade still pointed there.
Remove-Item -Force "$Bin\postgrest.exe" -ErrorAction SilentlyContinue
Set-Content -Encoding ascii "$Etc\version" $Ref

} catch {
    # Any failure after the old tree moved aside (a uv sync behind a proxy, a
    # locked file, the schema), not just a hub that won't start: put it back.
    $restored = $false
    if ($canRollBack) { try { $restored = RestorePrevious } catch { } }  # never mask the first error
    if ($restored) {
        Write-Host "   The previous version ($prevRef) is back, so guppi still works." -ForegroundColor Yellow
    }
    throw
} finally {
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Guppi $Ref is installed." -ForegroundColor Green
Write-Host '  Open a NEW terminal (so it sees the updated PATH), then:'
Write-Host '    guppi up        start the bench (hub + rack); Ctrl-C stops it'
Write-Host '  Then open http://localhost:8000 and plug in your instruments: the dashboard offers to add them.'
if ($Shared) {
    Write-Host '  Other computers on this network can open it too (guppi up prints the address).'
} else {
    Write-Host '  Only this PC can open it. For other computers too, re-run the installer with -Network.'
}
Write-Host '  Setup guide: https://guppidev.com/setup'

} finally {
    foreach ($name in $SavedEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $SavedEnv[$name], 'Process') }
}
}  # the child scope opened under param()
