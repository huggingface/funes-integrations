# funes's Claude Code integration on Windows, which funes runs with Windows PowerShell 5.1, as it
# runs `setup` on Linux and macOS: register `funes mcp` as a user-scoped MCP server, and install a
# plugin with a memory skill and hooks that index each turn and, with a memory bound, publish at
# session boundaries. funes never edits the user's settings.json.
#
#   setup.ps1 add [MEMORY] | setup.ps1 remove
#
# Nothing is installed for it: the converter and the hooks run on Windows PowerShell too. No funes
# before the registry ran on Windows, so unlike `setup` this script has no earlier install to clear.
# The file is ASCII: Windows PowerShell reads a script without a byte-order mark in the system code
# page.

$ErrorActionPreference = 'Stop'

$Here = $PSScriptRoot
$PluginRoot = Join-Path $Here 'claude-plugin'
$Plugin = Join-Path $PluginRoot 'funes'
$Scripts = Join-Path $Plugin 'scripts'
$PluginId = 'funes@huggingface'
$Marketplace = 'huggingface'
$UserHome = $env:USERPROFILE
if (-not $UserHome) { $UserHome = [Environment]::GetFolderPath('UserProfile') }

$Funes = $env:FUNES_BIN
if (-not $Funes) { $Funes = 'funes' }
# funes's MCP server names funes and this agent in its Hub requests: hf-hub appends
# HF_HUB_USER_AGENT_ORIGIN to its User-Agent. The registration is static, so the agent's version,
# which the hooks add, is left out.
$McpEnv = 'HF_HUB_USER_AGENT_ORIGIN=funes; agent/claude'
$Utf8 = [System.Text.UTF8Encoding]::new($false)

. (Join-Path $Plugin 'convert.ps1')

function Exit-Usage {
    [Console]::Error.WriteLine('usage: setup.ps1 add [MEMORY] | setup.ps1 remove')
    exit 2
}

function Test-Claude { $null -ne (Get-Command claude -ErrorAction SilentlyContinue) }

# Run `claude` with its output on the console, and return its exit status.
function Invoke-Claude([string[]]$arguments) {
    $ErrorActionPreference = 'Continue'
    & claude @arguments | Out-Host
    return $LASTEXITCODE
}

# Run `claude` with its output thrown away.
function Invoke-ClaudeQuietly([string[]]$arguments) {
    $ErrorActionPreference = 'Continue'
    & claude @arguments *> $null
}

# The directory funes drains for this agent. funes hands us its home and our id; the hook sees
# neither, so the resolved path is written beside it.
function Get-ClaudeSpool {
    $root = $env:FUNES_HOME
    if (-not $root) { $root = Join-Path $UserHome '.funes' }
    $id = $env:FUNES_AGENT_ID
    if (-not $id) { $id = 'claude' }
    return "$root/spool/$id"
}

function Set-ClaudeRecord([string]$name, [string]$value) {
    [IO.File]::WriteAllText((Join-Path $Scripts $name), "$value`n", $Utf8)
}

function Remove-ClaudePath([string]$path) {
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

# What the local memory holds, as `<session id> <stamp of its last indexed turn> <turn count>` lines:
# each `funes sessions` row, walked a page at a time from the offset each page names. A row with no
# span (funes before 1.9.0) gives the session id alone. With no funes to ask, nothing is listed.
function Get-ClaudeIndexed {
    $rows = [System.Collections.Generic.List[string]]::new()
    $exe = Resolve-Funes
    if (-not $exe) { return , $rows }
    $span = [regex]::new('^\[[^ ]* ' + [char]0x2192 + ' ([^\]]*)\] .* ([0-9]+) turns (.*)$')
    $day = [regex]::new('^\[[^\] ]*\] .* turns (.*)$')
    $next = [regex]::new('.* continue with --offset ([0-9]*),')
    $offset = '0'
    while ($offset) {
        $page = Get-FunesOutput $exe @('sessions', '--memory', 'local', '--limit', '200', '--offset', $offset)
        if ($null -eq $page) { break }
        $offset = ''
        foreach ($line in $page.Split([char]10)) {
            $line = $line.TrimEnd([char]13)
            $m = $span.Match($line)
            if ($m.Success) { $rows.Add($m.Groups[3].Value + ' ' + $m.Groups[1].Value + ' ' + $m.Groups[2].Value); continue }
            $m = $day.Match($line)
            if ($m.Success) { $rows.Add($m.Groups[1].Value); continue }
            $m = $next.Match($line)
            if ($m.Success) { $offset = $m.Groups[1].Value }
        }
    }
    return , $rows
}

# A transcript's last turn as `<session id> <stamp>`, converted from its last lines alone: a turn is
# made from its own line, and Claude Code writes only a few records after the last one.
function Get-ClaudeLastTurn([string]$src) {
    try { $lines = (Read-FunesText $src).TrimEnd([char]10).Split([char]10) } catch { return '' }
    $tail = [string]::Join("`n", @($lines | Select-Object -Last 32))
    $harness = $env:FUNES_AGENT_ID
    if (-not $harness) { $harness = 'claude' }
    $turns = ConvertFrom-ClaudeTranscript $tail (Get-ClaudeStem $src) $harness ''
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

# Convert the transcripts Claude Code has already written, so recall reaches them before the next
# turn. Sub-agent transcripts nest under their session's directory and are picked up by the same
# walk. The journal a workflow keeps beside its sub-agents holds no turn and is left out. What the
# memory holds stays beside the scripts, where the converter reads the numbering each session was
# indexed with.
#
# The walk shares the mark the hooks' sweeps keep: every transcript older than it was converted as
# it stands, by the walk that stamped it or by a sweep since. So a re-run reads the transcripts
# newer than the mark alone, and converts each unless its last turn is one the memory holds. Every
# transcript is read when there is no mark, or when a session the rows of the last walk list is
# gone from the memory (one rebuilt since). Like a sweep, the walk stamps its mark before it reads
# anything, and keeps it only when every conversion succeeded.
function Invoke-ClaudeSeed([string]$spool) {
    # Claude Code keeps its transcripts under its config directory, which `CLAUDE_CONFIG_DIR` moves.
    $config = $env:CLAUDE_CONFIG_DIR
    if (-not $config) { $config = Join-Path $UserHome '.claude' }
    $projects = Join-Path $config 'projects'
    if (-not [IO.Directory]::Exists($projects)) { return }
    $rows = Join-Path $Scripts 'indexed'
    $mark = Join-Path $Scripts 'converted'
    $stamp = "$mark.$PID"
    try {
        $held = Get-ClaudeIndexed
        [IO.File]::WriteAllText("$rows.new", $(if ($held.Count) { [string]::Join("`n", $held) + "`n" } else { '' }), $Utf8)
        [IO.File]::WriteAllBytes($stamp, [byte[]]@())
        [IO.File]::SetLastWriteTimeUtc($stamp, [DateTime]::UtcNow)
        $since = $null
        if ([IO.File]::Exists($mark) -and [IO.File]::Exists($rows) -and -not (Test-ClaudeLost $rows $held)) {
            $since = [IO.File]::GetLastWriteTimeUtc($mark)
        }
        $keep = { param($name) $name.EndsWith('.jsonl', [StringComparison]::Ordinal) -and $name -cne 'journal.jsonl' }
        $transcripts = Get-FunesFiles $projects $keep $since
        if ([IO.File]::Exists($rows)) { [IO.File]::Delete($rows) }
        [IO.File]::Move("$rows.new", $rows)
        $indexed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($row in $held) {
            $fields = $row.Split(' ')
            if ($fields.Length -eq 3) { [void]$indexed.Add($fields[0] + ' ' + $fields[1]) }
        }
        foreach ($src in $transcripts) {
            if ($indexed.Count -and $indexed.Contains((Get-ClaudeLastTurn $src))) { continue }
            try {
                Convert-ClaudeTranscript $src "$spool/$(Get-ClaudeStem $src).funes.jsonl" $rows
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

# Whether a session the rows file `$old` lists is missing from the rows `$new`: one the memory held
# at the last walk and holds no more.
function Test-ClaudeLost([string]$old, $new) {
    $held = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in $new) { [void]$held.Add($row.Split(' ')[0]) }
    foreach ($row in [IO.File]::ReadAllLines($old)) {
        if ($row -and -not $held.Contains($row.Split(' ')[0])) { return $true }
    }
    return $false
}

# The plugin's hooks: a static file per binding, plus the memory in a file the push hook reads. The
# hook commands never carry the memory, so nothing has to generate JSON.
function Set-ClaudeHooks([string]$memory) {
    $hooks = Join-Path $Plugin 'hooks'
    [void][IO.Directory]::CreateDirectory($hooks)
    if ($memory) {
        Copy-Item -LiteralPath (Join-Path $Here 'hooks-remote.windows.json') -Destination (Join-Path $hooks 'hooks.json') -Force
        Set-ClaudeRecord 'memory' $memory
    } else {
        Copy-Item -LiteralPath (Join-Path $Here 'hooks-local.windows.json') -Destination (Join-Path $hooks 'hooks.json') -Force
        Remove-ClaudePath (Join-Path $Scripts 'memory')
    }
}

function Write-ClaudeManualAdd([string]$memory) {
    Write-Output "  claude plugin marketplace add $PluginRoot"
    Write-Output "  claude plugin install $PluginId"
    $register = "  claude mcp add funes -s user -e `"$McpEnv`" -- $Funes mcp"
    if ($memory) { $register += " $memory" }
    Write-Output $register
}

function Add-Claude([string]$memory) {
    Set-ClaudeHooks $memory

    $spool = Get-ClaudeSpool
    [void][IO.Directory]::CreateDirectory($spool)
    Set-ClaudeRecord 'spool' $spool
    Invoke-ClaudeSeed $spool

    if (-not (Test-Claude)) {
        Write-Output "the funes plugin is installed at $PluginRoot"
        Write-Output '`claude` is not on PATH. Once it is, run:'
        Write-ClaudeManualAdd $memory
        return
    }

    if ((Invoke-Claude @('plugin', 'marketplace', 'add', $PluginRoot)) -ne 0) {
        [Console]::Error.WriteLine("``claude plugin`` couldn't take funes's marketplace: upgrade Claude Code (funes's hooks ride in a plugin), then run ``funes add claude`` again.")
        exit 1
    }
    # A plain install is a no-op for an installed plugin and update is version-gated, so refreshed
    # content lands by uninstalling first.
    Invoke-ClaudeQuietly @('plugin', 'uninstall', $PluginId)
    $rc = Invoke-Claude @('plugin', 'install', $PluginId)
    if ($rc -ne 0) { exit $rc }

    # `mcp add` errors when funes is already registered, so a re-run to change the memory would
    # fail without this.
    Invoke-ClaudeQuietly @('mcp', 'remove', 'funes')
    $register = @('mcp', 'add', 'funes', '-s', 'user', '-e', $McpEnv, '--', $Funes, 'mcp')
    if ($memory) { $register += $memory }
    $rc = Invoke-Claude $register
    if ($rc -ne 0) { exit $rc }

    if ($memory) {
        Write-Output "installed funes into Claude Code: recall, per-turn indexing, and publishing to $memory (restart Claude Code if it's running)."
    } else {
        Write-Output "installed funes into Claude Code: recall and per-turn indexing, local only (restart Claude Code if it's running)."
    }
}

# Run one `claude` removal. A registration claude has already forgotten is a success; any other
# failure keeps its diagnostics rather than claiming a partial uninstall worked.
function Remove-ClaudeRegistration([string]$absent, [string[]]$arguments) {
    $ErrorActionPreference = 'Continue'
    $out = & claude @arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -and -not $out.Contains($absent)) {
        [Console]::Error.WriteLine($out.TrimEnd())
        exit 1
    }
}

function Remove-Claude {
    # The spool holds converted copies of Claude Code's own transcripts, so dropping it loses nothing
    # a re-add cannot rebuild, and leaving it would have funes keep indexing an agent it no longer
    # serves.
    Remove-ClaudePath (Get-ClaudeSpool)
    foreach ($name in 'spool', 'converted', 'indexed', 'pushed') { Remove-ClaudePath (Join-Path $Scripts $name) }

    if (-not (Test-Claude)) {
        Write-Output '`claude` is not on PATH: the plugin files were removed. Once it is, remove the registrations manually:'
        Write-Output '  claude mcp remove funes -s user'
        Write-Output "  claude plugin uninstall $PluginId"
        Write-Output "  claude plugin marketplace remove $Marketplace"
        return
    }

    Remove-ClaudeRegistration 'No MCP server named "funes"' @('mcp', 'remove', 'funes', '-s', 'user')
    Remove-ClaudeRegistration "Plugin `"$PluginId`" not found" @('plugin', 'uninstall', $PluginId)
    Remove-ClaudeRegistration "Marketplace '$Marketplace' not found" @('plugin', 'marketplace', 'remove', $Marketplace)
    Write-Output 'removed funes from Claude Code: recall registration, hooks plugin, and installed files.'
}

switch -CaseSensitive ($args[0]) {
    'add' {
        if ($args.Count -gt 2) { Exit-Usage }
        $memory = ''
        if ($args.Count -eq 2) { $memory = $args[1] }
        Add-Claude $memory
    }
    'remove' {
        if ($args.Count -ne 1) { Exit-Usage }
        Remove-Claude
    }
    default { Exit-Usage }
}
exit 0
