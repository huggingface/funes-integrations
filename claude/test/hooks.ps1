# hooks.sh, for funes-index.ps1: the per-turn hook converts the transcript its payload names, then
# every transcript changed since the hook last ran (the sessions whose own hook never fired), and a
# boundary converts before it publishes. Drives the worker half against a fake Claude home, with a
# `funes` that only records what it is asked, so the conversion alone is under test.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File claude/test/hooks.ps1

$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
$Bundle = Split-Path -Parent $Here
. (Join-Path $Here 'fake.ps1')
. (Join-Path $Bundle 'claude-plugin\funes\convert.ps1')

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('funes-claude-hooks.' + [IO.Path]::GetRandomFileName())
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Fail([string]$message) {
    [Console]::Error.WriteLine("claude hooks: $message")
    exit 1
}

function Write-Text([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, $utf8) }
function Read-Text([string]$path) { if ([IO.File]::Exists($path)) { [IO.File]::ReadAllText($path) } else { '' } }
function Test-File([string]$path) { [IO.File]::Exists($path) }

try {
    $userHome = Join-Path $tmp 'home'
    $bin = Join-Path $tmp 'bin'
    [void][IO.Directory]::CreateDirectory((Join-Path $userHome '.funes\agents'))
    New-FunesFake $bin @('funes')
    $env:USERPROFILE = $userHome
    $env:PATH = Get-FunesTestPath $bin
    $log = Join-Path $tmp 'cli.log'
    $env:FUNES_TEST_CLI_LOG = $log
    Remove-Item Env:FUNES_TEST_PAGES -ErrorAction SilentlyContinue
    # funes and the agent are named after an origin the user set.
    $env:HF_HUB_USER_AGENT_ORIGIN = 'mine'
    # Claude Code's transcripts live under its config directory, wherever the user put it.
    $env:CLAUDE_CONFIG_DIR = Join-Path $tmp 'claude-config'

    # Installed, with the `spool` record `setup add` writes beside the scripts.
    $installed = Join-Path $userHome '.funes\agents\claude'
    Copy-Item -LiteralPath $Bundle -Destination $installed -Recurse
    $plugin = Join-Path $installed 'claude-plugin\funes'
    $scripts = Join-Path $plugin 'scripts'
    $script = Join-Path $scripts 'funes-index.ps1'
    $spool = Join-Path $tmp 'spool'
    [void][IO.Directory]::CreateDirectory($spool)
    Write-Text (Join-Path $scripts 'spool') "$spool`n"
    $tree = Join-Path $env:CLAUDE_CONFIG_DIR 'projects\-Users-me-repo'
    [void][IO.Directory]::CreateDirectory($tree)
    $fixture = Read-Text (Join-Path $Bundle 'claude-plugin\funes\test\session.jsonl')

    # The converter, wrapped so a test can act on one transcript as the hook converts it:
    # - `$ctl\<stem>.fail` fails its conversion;
    # - `$ctl\<stem>.hold` holds its conversion until the file is removed, and `<stem>.held` says it
    #   started;
    # - the lines of `$ctl\<stem>.late` are appended to the transcript once its conversion is done,
    #   as Claude Code writes a sub-agent's last turns after its SubagentStop fired.
    $ctl = Join-Path $tmp 'ctl'
    [void][IO.Directory]::CreateDirectory($ctl)
    Move-Item -LiteralPath (Join-Path $plugin 'convert.ps1') -Destination (Join-Path $plugin 'convert.real.ps1')
    Write-Text (Join-Path $plugin 'convert.ps1') (@'
. (Join-Path $PSScriptRoot 'convert.real.ps1')
$script:RealConvert = ${function:Convert-ClaudeTranscript}
function Convert-ClaudeTranscript([string]$src, [string]$out, [string]$rows) {
    $ctl = 'CTL'
    $stem = [IO.Path]::GetFileName($out) -replace '\.funes\.jsonl$', ''
    if ([IO.File]::Exists("$ctl\$stem.fail")) { throw "failed $stem, as the test asks" }
    if ([IO.File]::Exists("$ctl\$stem.hold")) {
        [IO.File]::WriteAllText("$ctl\$stem.held", '')
        while ([IO.File]::Exists("$ctl\$stem.hold")) { Start-Sleep -Milliseconds 100 }
    }
    & $script:RealConvert $src $out $rows
    if ([IO.File]::Exists("$ctl\$stem.late")) {
        Start-Sleep -Seconds 2
        [IO.File]::AppendAllText($src, [IO.File]::ReadAllText("$ctl\$stem.late"))
        [IO.File]::Delete("$ctl\$stem.late")
    }
}
'@).Replace('CTL', $ctl)

    # A transcript written now: a copy would keep the fixture's stamp, and the sweep goes by stamps.
    function New-Transcript([string]$name) { Write-Text (Join-Path $tree $name) $fixture }
    function New-Payload([string]$path, [string]$named) {
        $payload = $script:FunesJson.DeserializeObject('{}')
        $payload['transcript_path'] = $named
        Write-Text $path ($script:FunesJson.Serialize($payload))
    }
    # The worker half, as the foreground half runs it: the payload's file, then `--publish` at a
    # boundary. The payload names `a.jsonl` unless told another. The worker takes the file with it.
    function Invoke-Fire([string]$mode, [string]$name = 'a.jsonl', [string]$named = '') {
        if (-not $named) { $named = Join-Path $tree $name }
        $payload = Join-Path $tmp 'payload'
        New-Payload $payload $named
        $arguments = @('--worker', $payload)
        if ($mode) { $arguments += $mode }
        [void](Invoke-FunesTestScript $script $arguments)
        if (Test-File $payload) { Fail "the worker left the payload's file" }
    }
    # The filesystem stamps to the 100 ns, and the sweep compares stamps: a second is plenty.
    function Wait-Tick { Start-Sleep -Seconds 1 }
    # A worker in the background, its payload naming the transcript `$name`.
    function Start-Fire([string]$name) {
        $payload = Join-Path $tmp "payload-$name"
        New-Payload $payload (Join-Path $tree $name)
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath $powershell -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`" --worker `"$payload`"" -WindowStyle Hidden -PassThru
    }
    # Wait for a file a background worker creates, as long as a conversion could take.
    function Wait-File([string]$path, [string]$message) {
        for ($i = 0; $i -lt 300; $i++) {
            if (Test-File $path) { return }
            Start-Sleep -Milliseconds 100
        }
        Fail $message
    }
    $index = 'mine; funes; agent/claude; agent_version/2.1.175: index --harness claude'
    $push = 'mine; funes; agent/claude; agent_version/2.1.175: push acme/kb'
    function Assert-Asked([string[]]$want, [string]$when) {
        $got = Read-Text $log
        if ($got -cne ([string]::Join("`n", $want) + "`n")) { Fail "$when, funes was asked:`n$got" }
        Write-Text $log ''
    }
    function Set-Aged([string]$path) { [IO.File]::SetLastWriteTimeUtc($path, [DateTime]::Parse('2020-01-01T00:00:00Z').ToUniversalTime()) }

    # Two sessions written after the install, and the journal a workflow keeps beside its
    # sub-agents: the hook fires for one of the sessions only.
    Wait-Tick
    New-Transcript 'a.jsonl'
    New-Transcript 'b.jsonl'
    $journal = Join-Path $tree 'a\subagents\workflows\wf_1\journal.jsonl'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $journal))
    Write-Text $journal "{`"type`":`"started`",`"agentId`":`"agent-1`",`"key`":`"review`"}`n"
    Invoke-Fire
    if (-not (Test-File "$spool\a.funes.jsonl")) { Fail 'the session the payload named was not converted' }
    if (-not (Test-File "$spool\b.funes.jsonl")) { Fail 'the session whose hook never fired was not converted' }
    if (Test-File "$spool\journal.funes.jsonl") { Fail "a workflow's journal was converted" }
    if (-not (Test-File (Join-Path $scripts 'converted'))) { Fail 'the sweep left no mark' }

    # A third, written after that run; the second, drained by funes meanwhile, is not re-emitted.
    Wait-Tick
    New-Transcript 'c.jsonl'
    Remove-Item -LiteralPath "$spool\b.funes.jsonl"
    Invoke-Fire
    if (-not (Test-File "$spool\c.funes.jsonl")) { Fail 'a session written since the last sweep was not converted' }
    if (Test-File "$spool\b.funes.jsonl") { Fail 'a session unchanged since the last sweep was converted again' }

    # A payload naming its transcript in another spelling, as Windows takes it: converted once,
    # under its own stem.
    Wait-Tick
    New-Transcript 'g.jsonl'
    $agentLog = Join-Path $scripts 'funes-sync.log'
    Write-Text $agentLog ''
    Invoke-Fire '' '' ((Join-Path $tree 'g.jsonl').Replace('\', '/').ToUpperInvariant().Replace('/G.JSONL', '/g.jsonl'))
    $converted = @([IO.File]::ReadAllLines($agentLog) | Where-Object { $_.EndsWith(' convert: g') }).Count
    if ($converted -ne 1) { Fail "a transcript the payload spelled otherwise was converted $converted times:`n$(Read-Text $agentLog)" }
    Write-Text $log ''

    # A boundary: what was written since is converted first, then the index and the push to the
    # memory recorded beside the scripts.
    Wait-Tick
    New-Transcript 'd.jsonl'
    Write-Text (Join-Path $scripts 'memory') "acme/kb`n"
    Invoke-Fire '--publish'
    if (-not (Test-File "$spool\d.funes.jsonl")) { Fail 'the boundary did not convert before publishing' }
    Assert-Asked @($push.Replace('push acme/kb', 'index --harness claude'), $push) 'at a boundary'

    # A session can stop without its end firing, so with a memory bound a turn pushes too, once the
    # last push is an hour old: not right after the boundary's push, then at the turn after that
    # push has aged, which leaves the next turn to index alone.
    Invoke-Fire
    Set-Aged (Join-Path $scripts 'pushed')
    Invoke-Fire
    Invoke-Fire
    Assert-Asked @($index, $index, $push, $index) 'turn after turn'

    # A turn whose index fails does not push, even when a push is due: it would miss that turn. The
    # stamp stays as it was, so the next turn that indexes pushes.
    Set-Aged (Join-Path $scripts 'pushed')
    Write-Text "$log.busy" ''
    Invoke-Fire
    Remove-Item -LiteralPath "$log.busy"
    Invoke-Fire
    Assert-Asked @($index, $index, $push) 'around a failed index'

    # A boundary whose index never goes through still pushes what the memory holds, and leaves the
    # stamp as it was, so the next turn that indexes pushes what that push missed.
    Set-Aged (Join-Path $scripts 'pushed')
    Write-Text "$log.busy" ''
    Invoke-Fire '--publish'
    Remove-Item -LiteralPath "$log.busy"
    Invoke-Fire
    Assert-Asked @($index, $index, $index, $index, $index, $push, $index, $push) "around a boundary's failed index"

    # A session the memory holds without its queued messages keeps that numbering: the rows
    # `setup add` keeps beside the scripts reach the converter.
    Wait-Tick
    Write-Text (Join-Path $tree 'queued.jsonl') (Read-Text (Join-Path $Bundle 'claude-plugin\funes\test\queued.jsonl'))
    Write-Text (Join-Path $scripts 'indexed') "queued 2026-10-01T10:01:00.000Z 5`n"
    Invoke-Fire
    $uuids = @([IO.File]::ReadAllLines("$spool\queued.funes.jsonl") | ForEach-Object { $script:FunesJson.DeserializeObject($_)['turn_uuid'] }) -join ' '
    if ($uuids -cne 'u1 a1 a2 a3 u2 a4') { Fail "a session held without its queued messages took them: $uuids" }

    # What Claude Code writes while the hook converts the transcript it named, as a sub-agent's last
    # turns after its SubagentStop fired, is converted by the next sweep.
    Wait-Tick
    New-Transcript 'f.jsonl'
    Write-Text (Join-Path $ctl 'f.late') "{`"type`":`"user`",`"uuid`":`"late`",`"timestamp`":`"2026-06-12T22:00:00.000Z`",`"message`":{`"role`":`"user`",`"content`":`"late`"}}`n"
    Invoke-Fire '' 'f.jsonl'
    Wait-Tick
    Invoke-Fire
    if (-not (Read-Text "$spool\f.funes.jsonl").Contains('"text":"late"')) { Fail 'a turn written while the hook converted its transcript was never converted' }

    # Two runs side by side: the first holds its sweep, a session is written, and the second stamps
    # its mark before the first publishes. The session is newer than the first run's mark, so the
    # second run's sweep converts it.
    Wait-Tick
    New-Transcript 'p.jsonl'
    Write-Text (Join-Path $ctl 'p.hold') ''
    $first = Start-Fire 'a.jsonl'
    Wait-File (Join-Path $ctl 'p.held') 'the first run never reached its sweep'
    Wait-Tick
    New-Transcript 'q.jsonl'
    New-Transcript 'r.jsonl'
    Write-Text (Join-Path $ctl 'r.hold') ''
    Wait-Tick
    $second = Start-Fire 'r.jsonl'
    Wait-File (Join-Path $ctl 'r.held') 'the second run never converted the transcript it named'
    Remove-Item -LiteralPath (Join-Path $ctl 'p.hold')
    $first.WaitForExit()
    Remove-Item -LiteralPath (Join-Path $ctl 'r.hold')
    $second.WaitForExit()
    if (-not (Test-File "$spool\q.funes.jsonl")) { Fail 'a session written while two runs swept side by side was never converted' }

    # A conversion that fails leaves the mark where it was, so the next sweep tries the session
    # again, and the run leaves no stamp behind.
    Wait-Tick
    New-Transcript 'x.jsonl'
    Write-Text (Join-Path $ctl 'x.fail') ''
    Invoke-Fire
    if (@(Get-ChildItem -LiteralPath $scripts | Where-Object { $_.Name -like 'converted.*' }).Count) { Fail 'a run left its stamp behind' }
    Remove-Item -LiteralPath (Join-Path $ctl 'x.fail')
    Wait-Tick
    Invoke-Fire
    if (-not (Test-File "$spool\x.funes.jsonl")) { Fail 'a session whose conversion failed was never converted again' }

    # The foreground half, as Claude Code runs the hook on Windows: the program and arguments the
    # Windows hooks name, the plugin's root put in, with no shell between, and the payload on stdin
    # carrying an assistant message larger than any command line could. It hands the payload to a
    # detached worker and returns at once.
    Wait-Tick
    New-Transcript 'e.jsonl'
    $hook = $script:FunesJson.DeserializeObject((Read-Text (Join-Path $Bundle 'hooks-local.windows.json')))['hooks']['Stop'][0]['hooks'][0]
    $arguments = @($hook['args'] | ForEach-Object { $_.Replace('${CLAUDE_PLUGIN_ROOT}', $plugin) })
    $payload = $script:FunesJson.DeserializeObject('{}')
    # Cast: what a cmdlet returns is wrapped, and the writer cannot read through the wrapper.
    $payload['transcript_path'] = [string](Join-Path $tree 'e.jsonl')
    $payload['last_assistant_message'] = [string]::new([char]'x', 1100000)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $run = Invoke-FunesTestProgram (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\$($hook['command'])") $arguments ($script:FunesJson.Serialize($payload))
    if ($run.Code -ne 0) { Fail "the hook exited $($run.Code): $($run.Out)" }
    if ($clock.Elapsed.TotalSeconds -gt 10) { Fail "the hook took $($clock.Elapsed.TotalSeconds) s to return" }
    Wait-File "$spool\e.funes.jsonl" 'the detached worker never converted the session the hook named'
} finally {
    # A worker still running holds its files; what it leaves, the temporary directory keeps.
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output 'claude hooks: ok'
