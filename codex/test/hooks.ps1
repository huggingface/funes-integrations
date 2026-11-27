# hooks.sh, for funes-index.ps1: the per-turn hook converts the rollout its payload names, then
# every rollout changed since the hook last ran (the sessions whose own hook never fired), and a
# boundary converts before it publishes. Drives the worker half against a fake Codex home, with a
# `funes` that only records what it is asked, so the conversion alone is under test.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File codex/test/hooks.ps1

$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
$Bundle = Split-Path -Parent $Here
. (Join-Path $Here 'fake.ps1')
. (Join-Path $Bundle 'codex-plugin\plugins\funes\convert.ps1')

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('funes-codex-hooks.' + [IO.Path]::GetRandomFileName())
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Fail([string]$message) {
    [Console]::Error.WriteLine("codex hooks: $message")
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
    # The origin comes from the scripts, not from whoever ran the test.
    Remove-Item Env:HF_HUB_USER_AGENT_ORIGIN -ErrorAction SilentlyContinue
    Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
    # Codex names its hooks the directory it keeps for the plugin's data, outside the plugin whose
    # contents it pins when they are trusted: what a run writes goes there.
    $data = Join-Path $tmp 'plugin-data'
    $env:PLUGIN_DATA = $data

    # Installed with a memory bound: the `spool` record and the memory `setup.ps1 add` writes beside
    # the scripts.
    $installed = Join-Path $userHome '.funes\agents\codex'
    Copy-Item -LiteralPath $Bundle -Destination $installed -Recurse
    $plugin = Join-Path $installed 'codex-plugin\plugins\funes'
    $scripts = Join-Path $plugin 'scripts'
    $script = Join-Path $scripts 'funes-index.ps1'
    $spool = Join-Path $tmp 'spool'
    [void][IO.Directory]::CreateDirectory($spool)
    Write-Text (Join-Path $scripts 'spool') "$spool`n"
    Write-Text (Join-Path $scripts 'memory') "acme/kb`n"
    $tree = Join-Path $userHome '.codex\sessions\2026\09\24'
    [void][IO.Directory]::CreateDirectory($tree)
    $fixture = Read-Text (Join-Path $Bundle 'codex-plugin\plugins\funes\test\session.jsonl')

    # The converter, wrapped so a test can act on one rollout as the hook converts it:
    # - `$ctl\<stem>.fail` fails its conversion;
    # - `$ctl\<stem>.hold` holds its conversion until the file is removed, and `<stem>.held` says it
    #   started;
    # - the lines of `$ctl\<stem>.late` are appended to the rollout once its conversion is done, as
    #   a session writes on while the hook reads.
    $ctl = Join-Path $tmp 'ctl'
    [void][IO.Directory]::CreateDirectory($ctl)
    Move-Item -LiteralPath (Join-Path $plugin 'convert.ps1') -Destination (Join-Path $plugin 'convert.real.ps1')
    Write-Text (Join-Path $plugin 'convert.ps1') (@'
. (Join-Path $PSScriptRoot 'convert.real.ps1')
$script:RealConvert = ${function:Convert-CodexRollout}
function Convert-CodexRollout([string]$src, [string]$out) {
    $ctl = 'CTL'
    $stem = [IO.Path]::GetFileName($out) -replace '\.funes\.jsonl$', ''
    if ([IO.File]::Exists("$ctl\$stem.fail")) { throw "failed $stem, as the test asks" }
    if ([IO.File]::Exists("$ctl\$stem.hold")) {
        [IO.File]::WriteAllText("$ctl\$stem.held", '')
        while ([IO.File]::Exists("$ctl\$stem.hold")) { Start-Sleep -Milliseconds 100 }
    }
    & $script:RealConvert $src $out
    if ([IO.File]::Exists("$ctl\$stem.late")) {
        Start-Sleep -Seconds 2
        [IO.File]::AppendAllText($src, [IO.File]::ReadAllText("$ctl\$stem.late"))
        [IO.File]::Delete("$ctl\$stem.late")
    }
}
'@).Replace('CTL', $ctl)

    # A rollout written now: a copy would keep the fixture's stamp, and the sweep goes by stamps.
    function New-Rollout([string]$name) { Write-Text (Join-Path $tree $name) $fixture }
    function New-Payload([string]$path, [string]$named) {
        $payload = $script:FunesJson.DeserializeObject('{"session_id":"s"}')
        $payload['transcript_path'] = $named
        Write-Text $path ($script:FunesJson.Serialize($payload))
    }
    # The worker half, as the foreground half runs it: the payload's file, then `--publish` at a
    # boundary. The payload names `rollout-a.jsonl` unless told another. The worker takes the file
    # with it.
    function Invoke-Fire([string]$mode, [string]$name = 'rollout-a.jsonl') {
        $payload = Join-Path $tmp 'payload'
        New-Payload $payload ([string](Join-Path $tree $name))
        $arguments = @('--worker', $payload)
        if ($mode) { $arguments += $mode }
        [void](Invoke-FunesTestScript $script $arguments)
        if (Test-File $payload) { Fail "the worker left the payload's file" }
    }
    # The filesystem stamps to the 100 ns, and the sweep compares stamps: a second is plenty.
    function Wait-Tick { Start-Sleep -Seconds 1 }
    # A worker in the background, its payload naming the rollout `$name`.
    function Start-Fire([string]$name) {
        $payload = Join-Path $tmp "payload-$name"
        New-Payload $payload ([string](Join-Path $tree $name))
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
    $index = 'funes; agent/codex; agent_version/0.141.0: index --harness codex'
    $push = 'funes; agent/codex; agent_version/0.141.0: push acme/kb'
    function Assert-Asked([string[]]$want, [string]$when) {
        $got = Read-Text $log
        if ($got -cne ([string]::Join("`n", $want) + "`n")) { Fail "$when, funes was asked:`n$got" }
        Write-Text $log ''
    }
    function Set-Aged([string]$path) { [IO.File]::SetLastWriteTimeUtc($path, [DateTime]::Parse('2020-01-01T00:00:00Z').ToUniversalTime()) }
    # The plugin's paths, each file with its stamp: every run below must leave them as they are. A
    # directory's own stamp is left out, which NTFS settles a moment after a copy fills it.
    function Get-PluginState {
        @(Get-ChildItem -LiteralPath $plugin -Recurse -Force | Sort-Object FullName | ForEach-Object {
                if ($_ -is [System.IO.DirectoryInfo]) { $_.FullName } else { "$($_.FullName) $($_.LastWriteTimeUtc.Ticks)" }
            }) -join "`n"
    }
    $installedState = Get-PluginState

    # Two sessions written after the install: the hook fires for one of them only.
    Wait-Tick
    New-Rollout 'rollout-a.jsonl'
    New-Rollout 'rollout-b.jsonl'
    Invoke-Fire
    if (-not (Test-File "$spool\rollout-a.funes.jsonl")) { Fail 'the rollout the payload named was not converted' }
    if (-not (Test-File "$spool\rollout-b.funes.jsonl")) { Fail 'the rollout whose hook never fired was not converted' }
    if (-not (Test-File (Join-Path $data 'converted'))) { Fail 'the sweep left no mark' }

    # A third, written after that run; the second, drained by funes meanwhile, is not re-emitted.
    Wait-Tick
    New-Rollout 'rollout-c.jsonl'
    Remove-Item -LiteralPath "$spool\rollout-b.funes.jsonl"
    Invoke-Fire
    if (-not (Test-File "$spool\rollout-c.funes.jsonl")) { Fail 'a rollout written since the last sweep was not converted' }
    if (Test-File "$spool\rollout-b.funes.jsonl") { Fail 'a rollout unchanged since the last sweep was converted again' }

    # A boundary: what was written since is converted first, then the index and the push to the
    # memory recorded beside the scripts. Of the turns before it, the first had no push behind it
    # and pushed after its index, and the second indexed alone.
    Wait-Tick
    New-Rollout 'rollout-d.jsonl'
    Invoke-Fire '--publish'
    if (-not (Test-File "$spool\rollout-d.funes.jsonl")) { Fail 'the boundary did not convert before publishing' }
    Assert-Asked @($index, $push, $index, $index, $push) 'by the boundary'

    # A session can stop without its end firing, so a turn pushes too, once the last push is an hour
    # old: not right after the boundary's push, then at the turn after that push has aged, which
    # leaves the next turn to index alone.
    Invoke-Fire
    Set-Aged (Join-Path $data 'pushed')
    Invoke-Fire
    Invoke-Fire
    Assert-Asked @($index, $index, $push, $index) 'turn after turn'

    # A turn whose index fails does not push, even when a push is due: it would miss that turn. The
    # stamp stays as it was, so the next turn that indexes pushes.
    Set-Aged (Join-Path $data 'pushed')
    Write-Text "$log.busy" ''
    Invoke-Fire
    Remove-Item -LiteralPath "$log.busy"
    Invoke-Fire
    Assert-Asked @($index, $index, $push) 'around a failed index'

    # A boundary whose index never goes through still pushes what the memory holds, and leaves the
    # stamp as it was, so the next turn that indexes pushes what that push missed.
    Set-Aged (Join-Path $data 'pushed')
    Write-Text "$log.busy" ''
    Invoke-Fire '--publish'
    Remove-Item -LiteralPath "$log.busy"
    Invoke-Fire
    Assert-Asked @($index, $index, $index, $index, $index, $push, $index, $push) "around a boundary's failed index"

    # What a session writes while the hook converts the rollout it named is converted by the next
    # sweep.
    Wait-Tick
    New-Rollout 'rollout-f.jsonl'
    Write-Text (Join-Path $ctl 'rollout-f.late') ('{"timestamp": "2026-06-23T06:00:00.000Z", "type": "response_item", "payload": ' +
        "{`"type`": `"message`", `"role`": `"user`", `"content`": [{`"type`": `"input_text`", `"text`": `"late`"}]}}`n")
    Invoke-Fire '' 'rollout-f.jsonl'
    Wait-Tick
    Invoke-Fire
    if (-not (Read-Text "$spool\rollout-f.funes.jsonl").Contains('"text":"late"')) { Fail 'a turn written while the hook converted its rollout was never converted' }

    # Two runs side by side: the first holds its sweep, a session is written, and the second stamps
    # its mark before the first publishes. The session is newer than the first run's mark, so the
    # second run's sweep converts it.
    Wait-Tick
    New-Rollout 'rollout-p.jsonl'
    Write-Text (Join-Path $ctl 'rollout-p.hold') ''
    $first = Start-Fire 'rollout-a.jsonl'
    Wait-File (Join-Path $ctl 'rollout-p.held') 'the first run never reached its sweep'
    Wait-Tick
    New-Rollout 'rollout-q.jsonl'
    New-Rollout 'rollout-r.jsonl'
    Write-Text (Join-Path $ctl 'rollout-r.hold') ''
    Wait-Tick
    $second = Start-Fire 'rollout-r.jsonl'
    Wait-File (Join-Path $ctl 'rollout-r.held') 'the second run never converted the rollout it named'
    Remove-Item -LiteralPath (Join-Path $ctl 'rollout-p.hold')
    $first.WaitForExit()
    Remove-Item -LiteralPath (Join-Path $ctl 'rollout-r.hold')
    $second.WaitForExit()
    if (-not (Test-File "$spool\rollout-q.funes.jsonl")) { Fail 'a session written while two runs swept side by side was never converted' }

    # A conversion that fails leaves the mark where it was, so the next sweep tries the session
    # again, and the run leaves no stamp behind.
    Wait-Tick
    New-Rollout 'rollout-x.jsonl'
    Write-Text (Join-Path $ctl 'rollout-x.fail') ''
    Invoke-Fire
    if (@(Get-ChildItem -LiteralPath $data | Where-Object { $_.Name -like 'converted.*' }).Count) { Fail 'a run left its stamp behind' }
    Remove-Item -LiteralPath (Join-Path $ctl 'rollout-x.fail')
    Wait-Tick
    Invoke-Fire
    if (-not (Test-File "$spool\rollout-x.funes.jsonl")) { Fail 'a rollout whose conversion failed was never converted again' }

    # A payload with no rollout path, as an ephemeral run sends: the rollout named after its session
    # is converted.
    Wait-Tick
    New-Rollout 'rollout-2026-09-24T00-00-00-hid.jsonl'
    $payload = Join-Path $tmp 'payload'
    Write-Text $payload '{"transcript_path":null,"session_id":"hid"}'
    [void](Invoke-FunesTestScript $script @('--worker', $payload))
    if (-not (Read-Text (Join-Path $data 'funes-sync.log')).Contains('convert: rollout-2026-09-24T00-00-00-hid')) {
        Fail 'the rollout named after the session the payload carried was not converted'
    }

    # A run Codex hands no directory keeps its state where Codex has the plugin's data, which is
    # where the walk `setup.ps1 add` makes leaves the mark the sweeps share.
    Wait-Tick
    New-Rollout 'rollout-g.jsonl'
    Remove-Item Env:PLUGIN_DATA
    Invoke-Fire '' 'rollout-g.jsonl'
    $env:PLUGIN_DATA = $data
    if (-not (Test-File (Join-Path $userHome '.codex\plugins\data\funes-huggingface\converted'))) {
        Fail 'a run Codex named no directory to left its mark elsewhere'
    }

    # The foreground half, as Codex runs the hook on Windows: the hook's commandWindows, the plugin's
    # root put in, through PowerShell, with the payload on stdin carrying an assistant message larger
    # than any command line could. It hands the payload to a detached worker and returns at once.
    Wait-Tick
    New-Rollout 'rollout-e.jsonl'
    $hooks = $script:FunesJson.DeserializeObject((Read-Text (Join-Path $Bundle 'hooks-local.json')))
    $command = $hooks['hooks']['Stop'][0]['hooks'][0]['commandWindows'].Replace('${PLUGIN_ROOT}', $plugin)
    $payload = $script:FunesJson.DeserializeObject('{"session_id":"e"}')
    $payload['transcript_path'] = [string](Join-Path $tree 'rollout-e.jsonl')
    $payload['last_assistant_message'] = [string]::new([char]'x', 1100000)
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $run = Invoke-FunesTestProgram $powershell @('-NoProfile', '-Command', $command) ($script:FunesJson.Serialize($payload))
    if ($run.Code -ne 0) { Fail "the hook exited $($run.Code): $($run.Out)" }
    if ($clock.Elapsed.TotalSeconds -gt 10) { Fail "the hook took $($clock.Elapsed.TotalSeconds) s to return" }
    Wait-File "$spool\rollout-e.funes.jsonl" 'the detached worker never converted the rollout the hook named'
    # Trusting the hooks pins a hash of the plugin's contents: no run wrote into it.
    Start-Sleep -Seconds 2
    $state = Get-PluginState
    if ($state -cne $installedState) {
        $changed = Compare-Object ($installedState.Split([char]10)) ($state.Split([char]10)) | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }
        Fail "a run wrote into the plugin:`n$($changed -join "`n")"
    }
} finally {
    # A worker still running holds its files; what it leaves, the temporary directory keeps.
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output 'codex hooks: ok'
