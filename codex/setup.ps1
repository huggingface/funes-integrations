# funes's Codex integration on Windows, which funes runs with Windows PowerShell 5.1, as it runs
# `setup` on Linux and macOS: register `funes mcp` as an MCP server, and install a plugin carrying
# the skill Codex lists before any tool is loaded and the hooks that index each turn and, with a
# memory bound, publish at session boundaries. Codex writes its own config.toml; funes never does.
#
#   setup.ps1 add [MEMORY] | setup.ps1 remove
#
# Nothing is installed for it: the converter and the hooks run on Windows PowerShell too. No funes
# before the plugin ran on Windows, so unlike `setup` this script has no earlier install to clear.
# The file is ASCII: Windows PowerShell reads a script without a byte-order mark in the system code
# page.

$ErrorActionPreference = 'Stop'

$Here = $PSScriptRoot
# The marketplace root: the plugin itself sits at plugins\funes, where the marketplace points.
$PluginRoot = Join-Path $Here 'codex-plugin'
$PluginDir = Join-Path $PluginRoot 'plugins\funes'
$Scripts = Join-Path $PluginDir 'scripts'
$PluginId = 'funes@huggingface'
$Marketplace = 'huggingface'
$UserHome = $env:USERPROFILE
if (-not $UserHome) { $UserHome = [Environment]::GetFolderPath('UserProfile') }
# Codex answers `CODEX_HOME` itself, and its default lands in .codex under the user's home.
$CodexDir = $env:CODEX_HOME
if (-not $CodexDir) { $CodexDir = Join-Path $UserHome '.codex' }
# Where Codex keeps the plugin's data, `<plugin>-<marketplace>` under its home, and names to the
# hooks as PLUGIN_DATA: what the hooks write, and the mark and rows the walk below shares with their
# sweeps. It lies outside the plugin, whose whole contents Codex pins when the hooks are trusted.
$DataDir = Join-Path $CodexDir 'plugins\data\funes-huggingface'

$Funes = $env:FUNES_BIN
if (-not $Funes) { $Funes = 'funes' }
# funes's MCP server names funes and this agent in its Hub requests: hf-hub appends
# HF_HUB_USER_AGENT_ORIGIN to its User-Agent. The registration is static, so the agent's version,
# which the hooks add, is left out.
$McpEnv = 'HF_HUB_USER_AGENT_ORIGIN=funes; agent/codex'
$Utf8 = [System.Text.UTF8Encoding]::new($false)

. (Join-Path $PluginDir 'convert.ps1')

function Exit-Usage {
    [Console]::Error.WriteLine('usage: setup.ps1 add [MEMORY] | setup.ps1 remove')
    exit 2
}

function Test-Codex { $null -ne (Get-Command codex -ErrorAction SilentlyContinue) }

# Run `codex` with its output on the console, and return its exit status.
function Invoke-Codex([string[]]$arguments) {
    $ErrorActionPreference = 'Continue'
    & codex @arguments | Out-Host
    return $LASTEXITCODE
}

# The directory funes drains for this agent. funes hands us its home and our id; the hook sees
# neither, so the resolved path is written beside it.
function Get-CodexSpool {
    $root = $env:FUNES_HOME
    if (-not $root) { $root = Join-Path $UserHome '.funes' }
    $id = $env:FUNES_AGENT_ID
    if (-not $id) { $id = 'codex' }
    return "$root/spool/$id"
}

function Remove-CodexPath([string]$path) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
}

# funes as a program to start, or $null when there is none.
function Resolve-Funes {
    if ([IO.Path]::IsPathRooted($Funes)) { if ([IO.File]::Exists($Funes)) { return $Funes } else { return $null } }
    $found = Get-Command $Funes -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.Source }
    return $null
}

# What `funes` prints for `$arguments`, read as the UTF-8 it writes, or $null when it fails.
function Get-FunesOutput([string]$exe, [string[]]$arguments) {
    $info = [System.Diagnostics.ProcessStartInfo]::new($exe)
    $info.Arguments = [string]::Join(' ', $arguments)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $Utf8
    try { $process = [System.Diagnostics.Process]::Start($info) } catch { return $null }
    $null = $process.StandardError.ReadToEndAsync()
    $out = $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { return $null }
    return $out
}

# What the local memory holds, as `<session id> <stamp of its last indexed turn>` lines: the end of
# each `funes sessions` row, walked a page at a time from the offset each page names. A funes whose
# rows carry no span (before 1.9.0), or none to ask, lists nothing.
function Get-CodexIndexed {
    $rows = [System.Collections.Generic.List[string]]::new()
    $exe = Resolve-Funes
    if (-not $exe) { return , $rows }
    $span = [regex]::new('^\[[^ ]* ' + [char]0x2192 + ' ([^\]]*)\] .* turns (.*)$')
    $next = [regex]::new('.* continue with --offset ([0-9]*),')
    $offset = '0'
    while ($offset) {
        $page = Get-FunesOutput $exe @('sessions', '--memory', 'local', '--limit', '200', '--offset', $offset)
        if ($null -eq $page) { break }
        $offset = ''
        foreach ($line in $page.Split([char]10)) {
            $line = $line.TrimEnd([char]13)
            $m = $span.Match($line)
            if ($m.Success) { $rows.Add($m.Groups[2].Value + ' ' + $m.Groups[1].Value); continue }
            $m = $next.Match($line)
            if ($m.Success) { $offset = $m.Groups[1].Value }
        }
    }
    return , $rows
}

# A rollout's last turn as `<session id> <stamp>`, converted from its first line, which names the
# session, and its last lines: a turn is made from its own line alone, and Codex writes only a few
# records after the last one.
function Get-CodexLastTurn([string]$src) {
    try { $lines = (Read-FunesText $src).TrimEnd([char]10).Split([char]10) } catch { return '' }
    $sample = [string]::Join("`n", @(@($lines[0]) + @($lines | Select-Object -Last 32)))
    $turns = ConvertFrom-CodexRollout $sample ([IO.Path]::GetFileNameWithoutExtension($src))
    if (-not $turns.Count) { return '' }
    $last = $script:FunesJson.DeserializeObject($turns[$turns.Count - 1])
    return "$($last['session_id']) $($last['ts'])"
}

# The files under `$root` whose name `$keep` accepts, written after `$since` when it is given. A
# directory link is not followed, as `find` follows none.
function Get-FunesFiles([string]$root, [scriptblock]$keep, $since) {
    $found = [System.Collections.Generic.List[string]]::new()
    $dirs = [System.Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
    $dirs.Push([System.IO.DirectoryInfo]::new($root))
    while ($dirs.Count) {
        $dir = $dirs.Pop()
        try { $entries = $dir.GetFileSystemInfos() } catch { continue }
        foreach ($entry in $entries) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($entry -is [System.IO.DirectoryInfo]) { $dirs.Push($entry); continue }
            if (-not (& $keep $entry.Name)) { continue }
            if ($null -ne $since -and $entry.LastWriteTimeUtc -le $since) { continue }
            $found.Add($entry.FullName)
        }
    }
    return , $found
}

# Whether a session the rows file `$old` lists is missing from the rows `$new`: one the memory held
# at the last walk and holds no more.
function Test-CodexLost([string]$old, $new) {
    $held = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in $new) { [void]$held.Add($row.Split(' ')[0]) }
    foreach ($row in [IO.File]::ReadAllLines($old)) {
        if ($row -and -not $held.Contains($row.Split(' ')[0])) { return $true }
    }
    return $false
}

# Convert the rollouts Codex has already written, so recall reaches them before the next turn. What
# the memory holds stays in the plugin's data directory, for the next walk to tell what it lost.
#
# The walk shares the mark the hooks' sweeps keep: every rollout older than it was converted as it
# stands, by the walk that stamped it or by a sweep since. So a re-run reads the rollouts newer than
# the mark alone, and converts each unless its last turn is one the memory holds. Every rollout is
# read when there is no mark, or when a session the rows of the last walk list is gone from the
# memory (one rebuilt since). Like a sweep, the walk stamps its mark before it reads anything, and
# keeps it only when every conversion succeeded.
function Invoke-CodexSeed([string]$spool) {
    $sessions = Join-Path $CodexDir 'sessions'
    if (-not [IO.Directory]::Exists($sessions)) { return }
    $rows = Join-Path $DataDir 'indexed'
    $mark = Join-Path $DataDir 'converted'
    $stamp = "$mark.$PID"
    [void][IO.Directory]::CreateDirectory($DataDir)
    try {
        $held = Get-CodexIndexed
        [IO.File]::WriteAllText("$rows.new", $(if ($held.Count) { [string]::Join("`n", $held) + "`n" } else { '' }), $Utf8)
        [IO.File]::WriteAllBytes($stamp, [byte[]]@())
        [IO.File]::SetLastWriteTimeUtc($stamp, [DateTime]::UtcNow)
        $since = $null
        if ([IO.File]::Exists($mark) -and [IO.File]::Exists($rows) -and -not (Test-CodexLost $rows $held)) {
            $since = [IO.File]::GetLastWriteTimeUtc($mark)
        }
        $keep = { param($name) $name.StartsWith('rollout-', [StringComparison]::Ordinal) -and $name.EndsWith('.jsonl', [StringComparison]::Ordinal) }
        $rollouts = Get-FunesFiles $sessions $keep $since
        if ([IO.File]::Exists($rows)) { [IO.File]::Delete($rows) }
        [IO.File]::Move("$rows.new", $rows)
        $indexed = [System.Collections.Generic.HashSet[string]]::new([string[]]$held, [StringComparer]::Ordinal)
        foreach ($src in $rollouts) {
            if ($indexed.Count -and $indexed.Contains((Get-CodexLastTurn $src))) { continue }
            $stem = [IO.Path]::GetFileName($src)
            $stem = $stem.Substring(0, $stem.Length - 6)
            try {
                Convert-CodexRollout $src "$spool/$stem.funes.jsonl"
            } catch {
                [Console]::Error.WriteLine("convert: $src`: $($_.Exception.Message)")
                if ([IO.File]::Exists($stamp)) { [IO.File]::Delete($stamp) }
            }
        }
        if ([IO.File]::Exists($stamp)) {
            if ([IO.File]::Exists($mark)) { [IO.File]::Delete($mark) }
            [IO.File]::Move($stamp, $mark)
        }
    } finally {
        foreach ($path in $stamp, "$rows.new") { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } }
    }
}

# The plugin's hooks: a static file per binding, plus the memory in a file the push hook reads. The
# hook commands never carry the memory, so nothing has to generate JSON. Each hook carries its
# command for Windows beside the one for Linux and macOS.
function Set-CodexHooks([string]$memory) {
    if ($memory) {
        Copy-Item -LiteralPath (Join-Path $Here 'hooks-remote.json') -Destination (Join-Path $PluginDir 'hooks.json') -Force
        [IO.File]::WriteAllText((Join-Path $Scripts 'memory'), "$memory`n", $Utf8)
    } else {
        Copy-Item -LiteralPath (Join-Path $Here 'hooks-local.json') -Destination (Join-Path $PluginDir 'hooks.json') -Force
        Remove-CodexPath (Join-Path $Scripts 'memory')
    }
}

function Write-CodexManualAdd([string]$memory) {
    Write-Output "  codex plugin marketplace add $PluginRoot"
    Write-Output "  codex plugin add $PluginId"
    $register = "  codex mcp add funes --env `"$McpEnv`" -- $Funes mcp"
    if ($memory) { $register += " $memory" }
    Write-Output $register
}

function Add-Codex([string]$memory) {
    Set-CodexHooks $memory

    $spool = Get-CodexSpool
    [void][IO.Directory]::CreateDirectory($spool)
    [IO.File]::WriteAllText((Join-Path $Scripts 'spool'), "$spool`n", $Utf8)
    Invoke-CodexSeed $spool

    if (-not (Test-Codex)) {
        Write-Output "the funes plugin is installed at $PluginDir"
        Write-Output '`codex` is not on PATH. Once it is, run:'
        Write-CodexManualAdd $memory
        return
    }

    if ((Invoke-Codex @('plugin', 'marketplace', 'add', $PluginRoot)) -ne 0) {
        [Console]::Error.WriteLine("``codex plugin`` couldn't take funes's marketplace: upgrade Codex (funes's hooks ride in a plugin), then run ``funes add codex`` again.")
        exit 1
    }
    # Installing an installed plugin re-copies the source, so refreshed hooks land without a version
    # bump; `mcp add` overwrites an existing registration, so a re-run may change the memory.
    $rc = Invoke-Codex @('plugin', 'add', $PluginId)
    if ($rc -ne 0) { exit $rc }
    $register = @('mcp', 'add', 'funes', '--env', $McpEnv, '--', $Funes, 'mcp')
    if ($memory) { $register += $memory }
    $rc = Invoke-Codex $register
    if ($rc -ne 0) { exit $rc }
    if ($memory) {
        Write-Output "installed funes into Codex: recall, per-turn indexing, and publishing to $memory."
    } else {
        Write-Output 'installed funes into Codex: recall and per-turn indexing, local only.'
    }
    # Codex skips a hook until its exact command is trusted, so an install that says nothing here
    # reads as automation that silently never runs.
    Write-Output 'run `/hooks` in Codex to review and trust them: until then Codex skips them.'
}

# Run one `codex` removal. A registration codex has already forgotten is a success; any other
# failure keeps its diagnostics rather than claiming a partial uninstall worked.
function Remove-CodexRegistration([string]$absent, [string[]]$arguments) {
    $ErrorActionPreference = 'Continue'
    $out = & codex @arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -and -not $out.Contains($absent)) {
        [Console]::Error.WriteLine($out.TrimEnd())
        exit 1
    }
}

function Remove-Codex {
    # The spool holds converted copies of Codex's own rollouts, so dropping it loses nothing a
    # re-add cannot rebuild, and leaving it would have funes keep indexing an agent it no longer
    # serves. The data directory holds the hooks' log and the mark of their sweeps, nothing a re-add
    # needs.
    Remove-CodexPath (Get-CodexSpool)
    Remove-CodexPath $DataDir
    Remove-CodexPath (Join-Path $Scripts 'spool')

    if (-not (Test-Codex)) {
        Write-Output '`codex` is not on PATH: the plugin files were removed. Once it is, remove the registrations manually:'
        Write-Output '  codex mcp remove funes'
        Write-Output "  codex plugin remove $PluginId"
        Write-Output "  codex plugin marketplace remove $Marketplace"
        return
    }

    Remove-CodexRegistration "No MCP server named 'funes' found" @('mcp', 'remove', 'funes')
    $rc = Invoke-Codex @('plugin', 'remove', $PluginId)
    if ($rc -ne 0) { exit $rc }
    Remove-CodexRegistration 'is not configured or installed' @('plugin', 'marketplace', 'remove', $Marketplace)
    Write-Output 'removed funes from Codex: recall registration, plugin, hooks, and skill.'
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
            Add-Codex $memory
        }
        'remove' {
            if ($args.Count -ne 1) { Exit-Usage }
            Remove-Codex
        }
        default { Exit-Usage }
    }
} finally {
    if ($consoleEncoding) { try { [Console]::OutputEncoding = $consoleEncoding } catch {} }
}
exit 0
