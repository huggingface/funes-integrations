# funes's pi integration on Windows, which funes runs with Windows PowerShell 5.1, as it runs
# `setup` on Linux and macOS: register this directory with pi as an extension, copy beside it the
# memory it recalls from and publishes to, and convert the sessions pi has already written.
#
#   setup.ps1 add [MEMORY] | setup.ps1 remove
#
# pi has no MCP client, so index.ts is one: it spawns `funes mcp` over stdio and registers whatever
# tools/list returns. It also converts each finished turn into the spool funes indexes, and starts
# the worker that indexes it on pi's own runtime, so nothing is installed for it. No funes before
# the registry ran on Windows, so unlike `setup` this script has no earlier install to clear. The
# file is ASCII: Windows PowerShell reads a script without a byte-order mark in the system code
# page.

$ErrorActionPreference = 'Stop'

$Here = $PSScriptRoot
$UserHome = $env:USERPROFILE
if (-not $UserHome) { $UserHome = [Environment]::GetFolderPath('UserProfile') }
$Utf8 = [System.Text.UTF8Encoding]::new($false)

# The tools' MCP schemas make optional arguments nullable unions, which pi validates correctly only
# from this version on. An older pi registers them, then rejects every call that omits one.
$MinPi = [version]'0.84.0'

function Exit-Usage {
    [Console]::Error.WriteLine('usage: setup.ps1 add [MEMORY] | setup.ps1 remove')
    exit 2
}

function Test-Pi { $null -ne (Get-Command pi -ErrorAction SilentlyContinue) }

function Set-PiRecord([string]$name, [string]$value) {
    [IO.File]::WriteAllText((Join-Path $Here $name), "$value`n", $Utf8)
}

function Remove-PiPath([string]$path) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
}

# The directory funes drains for this agent. funes hands us its home and our id; the extension sees
# neither, so the resolved path is written beside it.
function Get-PiSpool {
    $root = $env:FUNES_HOME
    if (-not $root) { $root = Join-Path $UserHome '.funes' }
    $id = $env:FUNES_AGENT_ID
    if (-not $id) { $id = 'pi' }
    return "$root/spool/$id"
}

# Where pi keeps its sessions: either override it honours, else the default.
function Get-PiSessions {
    if ($env:PI_CODING_AGENT_SESSION_DIR) { return $env:PI_CODING_AGENT_SESSION_DIR }
    $agent = $env:PI_CODING_AGENT_DIR
    if (-not $agent) { $agent = Join-Path $UserHome '.pi\agent' }
    return (Join-Path $agent 'sessions')
}

# Convert what pi has already written, so recall reaches it before the next turn. The extension runs
# the same module inside pi, which needs nothing installed; from here it needs a JS runtime, and
# where there is none the extension does this itself at its next start.
function Invoke-PiSeed([string]$spool) {
    $sessions = Get-PiSessions
    if (-not [IO.Directory]::Exists($sessions)) { return }
    foreach ($name in 'node', 'bun', 'deno') {
        $js = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $js) { continue }
        $arguments = @((Join-Path $Here 'convert.mjs'), $sessions, $spool)
        if ($name -eq 'deno') { $arguments = @('run', '--allow-all') + $arguments }
        $ErrorActionPreference = 'Continue'
        & $js.Source @arguments | Out-Null
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        Remove-PiPath (Join-Path $Here 'seed-pending')
        return
    }
    Set-PiRecord 'seed-pending' $sessions
    [Console]::Error.WriteLine('no JS runtime on PATH to convert your existing pi sessions: pi will convert them itself the next time it starts.')
}

# The version pi reports, or $null when it reports something with no version in it.
function Get-PiVersion {
    $ErrorActionPreference = 'Continue'
    $out = (& pi --version 2>$null | Out-String)
    if ($out -match '[0-9]+(\.[0-9]+)+') { return $Matches[0] }
    return $null
}

function Add-Pi([string]$memory) {
    # The memory index.ts reads at startup; absent is the local memory.
    if ($memory) { Set-PiRecord 'memory' $memory } else { Remove-PiPath (Join-Path $Here 'memory') }

    $spool = Get-PiSpool
    [void][IO.Directory]::CreateDirectory($spool)
    Set-PiRecord 'spool' $spool
    # The sessions root, for the extension's sweep: a session pi was pointed elsewhere is swept in
    # its own directory alone.
    Set-PiRecord 'sessions' (Get-PiSessions)
    Invoke-PiSeed $spool

    if (-not (Test-Pi)) {
        Write-Output "the funes pi extension is installed at $Here"
        Write-Output "``pi`` is not on PATH. Once it is, run:  pi install $Here"
        return
    }

    $version = Get-PiVersion
    if ($version) {
        $parts = @($version.Split('.') + @('0', '0') | Select-Object -First 3)
        if ([version]($parts -join '.') -lt $MinPi) {
            [Console]::Error.WriteLine("pi $version is too old for funes: the tools need pi $MinPi or newer to accept their arguments. Run ``pi update``, then re-run this command. The extension is installed at $Here either way.")
            exit 1
        }
    }

    $ErrorActionPreference = 'Continue'
    & pi install $Here | Out-Host
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $named = 'pi'
    if ($version) { $named = "pi $version" }
    Write-Output "installed funes into $named`: recall and per-turn indexing are now active (restart pi if it's running)."
}

function Remove-Pi {
    # The spool holds converted copies of pi's own sessions, so dropping it loses nothing a re-add
    # cannot rebuild, and leaving it would have funes keep indexing an agent it no longer serves.
    Remove-PiPath (Get-PiSpool)
    foreach ($name in 'memory', 'spool', 'sessions', 'seed-pending', 'swept', 'scripts\pushed') { Remove-PiPath (Join-Path $Here $name) }

    if (-not (Test-Pi)) {
        Write-Output "``pi`` is not on PATH: the extension and its automation were removed. Once it is, remove the registration manually:  pi remove $Here"
        return
    }

    # A registration pi has already forgotten is a success.
    $ErrorActionPreference = 'Continue'
    $out = & pi remove $Here 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -and -not $out.Contains('No matching package found for')) {
        [Console]::Error.WriteLine($out.TrimEnd())
        exit 1
    }
    Write-Output 'removed funes from pi: extension registration, its automation, and the extracted files.'
}

# The agents' own programs write UTF-8, which Windows PowerShell reads in the console's code page,
# garbling what is past ASCII on its way to the user. It is read as UTF-8 while this script runs,
# and the console gets its code page back after.
$consoleEncoding = $null
try {
    $consoleEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = $Utf8
} catch {}
try {
    switch -CaseSensitive ($args[0]) {
        'add' {
            if ($args.Count -gt 2) { Exit-Usage }
            $memory = ''
            if ($args.Count -eq 2) { $memory = $args[1] }
            Add-Pi $memory
        }
        'remove' {
            if ($args.Count -ne 1) { Exit-Usage }
            Remove-Pi
        }
        default { Exit-Usage }
    }
} finally {
    if ($consoleEncoding) { try { [Console]::OutputEncoding = $consoleEncoding } catch {} }
}
exit 0
