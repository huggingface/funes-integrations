# Claude Code's per-turn capture on Windows, run by Windows PowerShell 5.1, as funes-index.sh is on
# Linux and macOS: convert the transcript that just changed into funes's spool, then any other
# changed since the last run, then advance the index over it. Fired by Stop and by SubagentStop,
# whose payloads arrive on stdin, and, as `funes-index.ps1 --publish`, by the session boundaries,
# where the same conversion runs first and the publish follows it, so the last turn is in the spool
# before it is indexed and pushed. With a memory bound, a turn pushes as well, once the last push
# is `$PushEvery` minutes old.
#
#   funes-index.ps1 [--publish]                       the hook
#   funes-index.ps1 --worker <payload> [--publish]    the worker it leaves behind
#
# The hook copies the payload into a file and returns, so a turn never waits on the conversion or
# on the embedder; the worker it starts does both. Started through the shell, the worker holds none
# of the hook's handles, so Claude Code sees the hook end at once, and it outlives Claude Code.
#
# No locking: `funes` serializes local-memory writes itself. A run that loses the lock exits
# non-zero, is logged, and the next turn re-sweeps the same content: indexing is idempotent.
#
# The file is ASCII: Windows PowerShell reads a script without a byte-order mark in the system code
# page.

$Here = $PSScriptRoot
$Log = Join-Path $Here 'funes-sync.log'
$Harness = 'claude'
# How old the last push gets, in minutes, before a turn pushes too. A push compacts the remote once
# enough rows sit unindexed there, so many small pushes compact it more often than a few large ones.
$PushEvery = 60

# One line into the log, appended whole: workers side by side share it.
function Write-FunesLog([string]$text) {
    $offset = [DateTimeOffset]::Now
    $line = $offset.ToString("yyyy-MM-dd'T'HH:mm:ss") + $offset.ToString('zzz').Replace(':', '') + ' ' + $text + "`n"
    Add-FunesLogText $line
}

function Add-FunesLogText([string]$text) {
    if (-not $text) { return }
    try {
        $stream = [System.IO.FileStream]::new($Log, [IO.FileMode]::Append, [Security.AccessControl.FileSystemRights]::AppendData,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete), 4096, [IO.FileOptions]::None)
        try {
            $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($text)
            $stream.Write($bytes, 0, $bytes.Length)
        } finally {
            $stream.Dispose()
        }
    } catch {}
}

# The user's home, as Claude Code finds it.
function Get-FunesHome {
    if ($env:USERPROFILE) { return $env:USERPROFILE }
    return [Environment]::GetFolderPath('UserProfile')
}

# funes, from the absolute entries of PATH, then the directory its installer puts it in: a hook can
# run with a minimal PATH, launched from an IDE. A relative entry would be read against the
# directory the agent works in, so none is.
function Find-Funes {
    foreach ($dir in ($env:PATH -split ';')) {
        $dir = $dir.Trim().Trim('"')
        if ($dir -notmatch '^([A-Za-z]:[\\/]|\\\\)') { continue }
        try { $exe = [IO.Path]::Combine($dir, 'funes.exe') } catch { continue }
        if ([IO.File]::Exists($exe)) { return $exe }
    }
    $exe = [IO.Path]::Combine((Get-FunesHome), '.local', 'bin', 'funes.exe')
    if ([IO.File]::Exists($exe)) { return $exe }
    return $null
}

# An argument as a Windows program reads it back from its command line.
function ConvertTo-FunesArgument([string]$a) {
    if ($a -and $a -notmatch '[\s"]') { return $a }
    return '"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

# Run funes with `$arguments`, its output into the log, and return its exit status.
function Invoke-Funes([string[]]$arguments) {
    $info = [System.Diagnostics.ProcessStartInfo]::new($script:Funes)
    $info.Arguments = [string]::Join(' ', @($arguments | ForEach-Object { ConvertTo-FunesArgument $_ }))
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $info.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    try {
        $process = [System.Diagnostics.Process]::Start($info)
    } catch {
        Write-FunesLog "funes failed to start: $($_.Exception.Message)"
        return 127
    }
    $stderr = $process.StandardError.ReadToEndAsync()
    $stdout = $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()
    Add-FunesLogText ($stdout + $stderr.Result)
    return $process.ExitCode
}

# One transcript into the spool, named after the session it belongs to, which is its own file stem,
# and numbered as the memory holds it, from the rows `setup add` keeps beside this script. Returns
# whether the conversion went through.
function Convert-ClaudeOne([string]$src) {
    if (-not $src -or -not [IO.File]::Exists($src)) { return $true }
    $stem = Get-ClaudeStem $src
    try {
        Convert-ClaudeTranscript $src ([IO.Path]::Combine($script:Spool, "$stem.funes.jsonl")) (Join-Path $Here 'indexed')
        Write-FunesLog "convert: $stem"
        return $true
    } catch {
        Add-FunesLogText ("convert: " + $_.Exception.Message + "`n")
        Write-FunesLog "convert: FAILED for $src"
        return $false
    }
}

# Name funes, this agent and its version (when known) in funes's Hub requests: hf-hub appends
# HF_HUB_USER_AGENT_ORIGIN to its User-Agent. An origin already set is kept in front.
function Set-FunesHubOrigin([string]$version) {
    $origin = "funes; agent/$Harness"
    if ($version) { $origin += "; agent_version/$version" }
    if ($env:HF_HUB_USER_AGENT_ORIGIN) { $origin = "$($env:HF_HUB_USER_AGENT_ORIGIN); $origin" }
    $env:HF_HUB_USER_AGENT_ORIGIN = $origin
}

# The Claude Code version that wrote a transcript: every record carries it, so its last lines
# settle it.
function Get-ClaudeVersion([string]$src) {
    if (-not $src -or -not [IO.File]::Exists($src)) { return '' }
    try { $lines = (Read-FunesText $src).TrimEnd([char]10).Split([char]10) } catch { return '' }
    $version = ''
    foreach ($line in ($lines | Select-Object -Last 20)) {
        try { $r = $script:FunesJson.DeserializeObject($line) } catch { continue }
        if ($r -is $script:FunesDict -and $r['version'] -is [string]) { $version = $r['version'] }
    }
    return $version
}

# Whether two paths name the same file, as Windows compares them.
function Test-FunesSamePath([string]$a, [string]$b) {
    if (-not $a -or -not $b) { return $false }
    try { return [string]::Equals([IO.Path]::GetFullPath($a), [IO.Path]::GetFullPath($b), [StringComparison]::OrdinalIgnoreCase) } catch { return $false }
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

# The transcripts changed since the last sweep: sessions whose own hook never fired (untrusted,
# timed out, a host that died mid-turn) and the sub-agents a workflow nests under a session, whose
# SubagentStop funes may not see. What the spool holds cannot say which those are (funes drains it),
# so the sweep goes by a mark it shares with the walk `setup add` makes over the history: the stamp
# of the last of them, or, before there is one, the `spool` record `setup add` wrote just before
# that walk. The transcript the payload named was converted already and is skipped. The next mark is
# the stamp `$stamp` the worker took before it converted anything, unless a conversion failed and
# dropped it. The journal a workflow keeps beside its sub-agents holds no turn and is left out.
function Convert-ClaudeStale([string]$named, [string]$stamp) {
    $config = $env:CLAUDE_CONFIG_DIR
    if (-not $config) { $config = Join-Path (Get-FunesHome) '.claude' }
    $projects = Join-Path $config 'projects'
    if (-not [IO.Directory]::Exists($projects)) { return }
    $mark = Join-Path $Here 'converted'
    $since = $mark
    if (-not [IO.File]::Exists($since)) { $since = Join-Path $Here 'spool' }
    $keep = { param($name) $name.EndsWith('.jsonl', [StringComparison]::Ordinal) -and $name -cne 'journal.jsonl' }
    foreach ($src in (Get-FunesFiles $projects $keep ([IO.File]::GetLastWriteTimeUtc($since)))) {
        if (Test-FunesSamePath $src $named) { continue }
        if (-not (Convert-ClaudeOne $src)) { Remove-FunesFile $stamp }
    }
    if ([IO.File]::Exists($stamp)) { Move-FunesFile $stamp $mark }
}

function Remove-FunesFile([string]$path) {
    try { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } } catch {}
}

function Move-FunesFile([string]$from, [string]$to) {
    try {
        if ([IO.File]::Exists($to)) { [IO.File]::Delete($to) }
        [IO.File]::Move($from, $to)
    } catch {}
}

# An empty file, stamped now.
function New-FunesStamp([string]$path) {
    [IO.File]::WriteAllBytes($path, [byte[]]@())
    [IO.File]::SetLastWriteTimeUtc($path, [DateTime]::UtcNow)
}

# The memory `setup add` recorded beside this script, empty when it was handed none.
function Get-FunesBoundMemory {
    $file = Join-Path $Here 'memory'
    if (-not [IO.File]::Exists($file)) { return '' }
    try { $lines = [IO.File]::ReadAllLines($file) } catch { return '' }
    if (-not $lines.Count) { return '' }
    return ($lines[0] -replace '\s', '')
}

# Push what the local memory holds to the memory `$memory`. A first push to a memory this index
# shares no chunks with is refused off a terminal. funes does it once, interactively, when it binds
# the memory.
function Invoke-FunesPush([string]$memory) {
    Write-FunesLog "push: start ($memory)"
    $rc = Invoke-Funes @('push', $memory)
    if ($rc -eq 0) { Write-FunesLog 'push: ok' }
    elseif ($rc -eq 2) { Write-FunesLog 'push: WARN - secrets held back; run `funes scrub`, then it publishes next run' }
    else { Write-FunesLog "push: FAILED (exit $rc)" }
}

# The boundary's second half: land the turns in the memory, waiting out a per-turn worker that may
# still hold its lock, then push them to the memory `setup add` recorded beside this script. A push
# after an index that never went through misses the last turns, so it leaves the `pushed` stamp as
# it was, and the next turn that indexes pushes them.
function Invoke-FunesPublish {
    $indexed = $false
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        if ((Invoke-Funes @('index', '--harness', $Harness)) -eq 0) {
            Write-FunesLog "index[$Harness]: ok (before push)"
            $indexed = $true
            break
        }
        Write-FunesLog "index[$Harness]: busy or failed, retry $attempt"
        Start-Sleep -Seconds 2
    }
    $memory = Get-FunesBoundMemory
    if (-not $memory) {
        Write-FunesLog 'push: skipped (no memory bound)'
        return
    }
    if ($indexed) { New-FunesStamp (Join-Path $Here 'pushed') }
    Invoke-FunesPush $memory
}

function Invoke-FunesWorker([string]$payload, [string]$mode) {
    # The sweep's next mark, as this run stamps it: named after the process, so runs side by side
    # never publish each other's, and dropped on exit unless the sweep published it.
    $stamp = Join-Path $Here "converted.$PID"
    try {
        $script:Funes = Find-Funes
        if (-not $script:Funes) {
            Write-FunesLog 'index ABORT: funes not found; skipping.'
            return
        }
        $script:Spool = ''
        $record = Join-Path $Here 'spool'
        if ([IO.File]::Exists($record)) { $script:Spool = ([IO.File]::ReadAllText($record)).Trim() }
        if (-not $script:Spool) {
            Write-FunesLog 'convert ABORT: no spool recorded; re-run `funes add claude`.'
            return
        }

        # SubagentStop carries the sub-agent's own transcript in its own field; the session's is
        # still `transcript_path`. A reported bug fires the event for internal calls whose file
        # never exists, which Convert-ClaudeOne skips.
        $named = ''
        try {
            $hookEvent = $script:FunesJson.DeserializeObject((Read-FunesText $payload))
            if ($hookEvent -is $script:FunesDict) {
                if ($hookEvent['transcript_path'] -is [string]) { $named = $hookEvent['transcript_path'] }
                if ($hookEvent['agent_transcript_path'] -is [string] -and $hookEvent['agent_transcript_path']) { $named = $hookEvent['agent_transcript_path'] }
            }
        } catch {}
        Set-FunesHubOrigin (Get-ClaudeVersion $named)
        # Stamped before anything is converted, the named transcript included: what is written while
        # this run reads, such as a sub-agent's last turns after its SubagentStop fired, is newer
        # than the mark it leaves and is swept next turn. A failed conversion drops the stamp: the
        # mark stays where it was, and the next sweep tries again.
        New-FunesStamp $stamp
        if (-not (Convert-ClaudeOne $named)) { Remove-FunesFile $stamp }
        Convert-ClaudeStale $named $stamp

        if ($mode -ceq '--publish') {
            Invoke-FunesPublish
            return
        }

        Write-FunesLog "index[$Harness]: start"
        $rc = Invoke-Funes @('index', '--harness', $Harness)
        if ($rc -ne 0) {
            Write-FunesLog "index[$Harness]: FAILED (exit $rc)"
            # A push now would miss this turn, and its stamp would hold the turn back `$PushEvery`
            # minutes more. The next turn that indexes pushes it.
            return
        }
        Write-FunesLog "index[$Harness]: ok"

        # A session can stop without its end firing (a conversation switched away, a window
        # closed, a host disconnected), so a turn publishes too, once the last push is `$PushEvery`
        # minutes old. The `pushed` stamp says when the last push after a successful index started,
        # whatever the push's outcome, so a failed push waits `$PushEvery` minutes rather than
        # retrying at every turn. Runs side by side may both push: funes lets one through and the
        # other steps aside.
        $memory = Get-FunesBoundMemory
        $pushed = Join-Path $Here 'pushed'
        if ($memory -and -not ([IO.File]::Exists($pushed) -and
                [IO.File]::GetLastWriteTimeUtc($pushed) -gt [DateTime]::UtcNow.AddMinutes(-$PushEvery))) {
            New-FunesStamp $pushed
            Invoke-FunesPush $memory
        }
    } catch {
        Write-FunesLog "index ABORT: $($_.Exception.Message)"
    } finally {
        Remove-FunesFile $payload
        Remove-FunesFile $stamp
    }
}

# Worker mode: the payload's file and the mode are the arguments, and the turn is already over.
if ($args.Count -ge 2 -and $args[0] -ceq '--worker') {
    $mode = ''
    if ($args.Count -ge 3) { $mode = $args[2] }
    try {
        . (Join-Path (Split-Path -Parent $Here) 'convert.ps1')
    } catch {
        Write-FunesLog "convert ABORT: $($_.Exception.Message)"
        Remove-FunesFile $args[1]
        exit 0
    }
    Invoke-FunesWorker $args[1] $mode
    exit 0
}

# The payload carries the last assistant message, which can outgrow what a command line holds, so
# it goes through a file the worker takes with it. A launch that fails is logged: nothing of it is
# worth failing the turn over.
try {
    $payload = Join-Path ([IO.Path]::GetTempPath()) ('funes-payload.' + [IO.Path]::GetRandomFileName())
    $file = [IO.File]::Create($payload)
    try { [Console]::OpenStandardInput().CopyTo($file) } finally { $file.Dispose() }
    $line = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" --worker "' + $payload + '"'
    if ($args.Count -ge 1) { $line += ' ' + $args[0] }
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $line -WindowStyle Hidden -WorkingDirectory $Here
} catch {
    Write-FunesLog "index ABORT: $($_.Exception.Message)"
}
exit 0
