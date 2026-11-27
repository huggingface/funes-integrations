# The converter's acceptance test on Windows: what run.sh checks of `convert`, checked of
# convert.ps1 against the same fixtures, so the two converters make the same turns byte for byte.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File <plugin>/test/run.ps1

$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
$Convert = Join-Path (Split-Path -Parent $Here) 'convert.ps1'
. $Convert

$out = Join-Path ([IO.Path]::GetTempPath()) ('funes-claude-convert.' + [IO.Path]::GetRandomFileName())
[void][IO.Directory]::CreateDirectory($out)

function Fail([string]$message) {
    [Console]::Error.WriteLine("claude converter: $message")
    exit 1
}

# The lines of two texts where they first differ, for a failure to show.
function Show-Difference([string]$want, [string]$got) {
    $a = $want.Split([char]10)
    $b = $got.Split([char]10)
    for ($i = 0; $i -lt [Math]::Max($a.Length, $b.Length); $i++) {
        if ($i -ge $a.Length -or $i -ge $b.Length -or $a[$i] -cne $b[$i]) {
            return "line $($i + 1)`n  want: $(if ($i -lt $a.Length) { $a[$i] })`n  got:  $(if ($i -lt $b.Length) { $b[$i] })"
        }
    }
    return 'no difference'
}

# The converter as a command, its stdout read as the UTF-8 it writes.
function Invoke-Convert([string[]]$arguments) {
    $info = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'powershell.exe'))
    $info.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $Convert + '" ' + [string]::Join(' ', @($arguments | ForEach-Object { '"' + $_ + '"' }))
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $process = [System.Diagnostics.Process]::Start($info)
    $stderr = $process.StandardError.ReadToEndAsync()
    $stdout = $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { Fail "convert.ps1 $arguments exited $($process.ExitCode): $($stderr.Result)" }
    return $stdout
}

try {
    $session = Join-Path $Here 'session.jsonl'
    $got = Join-Path $out 'got.funes.jsonl'
    [void](Invoke-Convert @($session, $got))
    $want = [IO.File]::ReadAllText((Join-Path $Here 'expected.funes.jsonl'))
    $text = [IO.File]::ReadAllText($got)
    if ($text -cne $want) { Fail "output changed: $(Show-Difference $want $text)" }
    if ([IO.File]::GetLastWriteTimeUtc($got) -ne [IO.File]::GetLastWriteTimeUtc($session)) {
        Fail "the turns file does not carry the transcript's own time"
    }
    if ((Invoke-Convert @($session)) -cne $want) { Fail 'the turns on stdout differ from the turns file' }

    # The numbering of a session the memory already holds, from its row in `--indexed`. In
    # `queued.jsonl`, q1 and q2 were typed while Claude was working, and a2 and a3 are one reply
    # written as two lines with one stamp.
    $all = 'u1 a1 q1 a2 a3 u2 q2 a4'
    $without = 'u1 a1 a2 a3 u2 a4'
    $rows = Join-Path $out 'rows'
    $queued = Join-Path $out 'queued.funes.jsonl'
    foreach ($case in @(
            # Not held.
            @('other 2026-10-01T10:00:10.000Z 4', $all),
            # Held without q1 up to u2, or with it.
            @('queued 2026-10-01T10:01:00.000Z 5', $without),
            @('queued 2026-10-01T10:01:00.000Z 6', $all),
            # Held up to a1, before either: the two counts agree.
            @('queued 2026-10-01T10:00:05.000Z 2', $all),
            # Up to a3 without q1, or up to a2 with it: read as held without.
            @('queued 2026-10-01T10:00:10.000Z 4', $without),
            # No stamp to compare (funes before 1.9.0), or one neither count matches.
            @('queued', $without),
            @('queued 2026-10-01T10:00:00.000Z 2', $without))) {
        [IO.File]::WriteAllText($rows, $case[0] + "`n")
        Convert-ClaudeTranscript (Join-Path $Here 'queued.jsonl') $queued $rows
        $uuids = @([IO.File]::ReadAllLines($queued) | ForEach-Object { $script:FunesJson.DeserializeObject($_)['turn_uuid'] }) -join ' '
        if ($uuids -cne $case[1]) { Fail "with the row `"$($case[0])`", the turns are $uuids, not $($case[1])" }
    }

    # Who wrote each line of `attribution.jsonl`, one line of every kind Claude Code writes, each
    # named by its uuid.
    $want = @(
        'prompt user text'
        'ask assistant tool_use:AskUserQuestion'
        'answer user text'
        'ask-again assistant tool_use:AskUserQuestion'
        'dismissed tool tool_result:AskUserQuestion'
        'call assistant tool_use:Bash'
        'output tool tool_result:Bash'
        'interrupt system text'
        'nudge system text'
        'notification system text'
        'peer system text'
        'recap system text'
        'placeholder system text'
        'api-error system text'
        'reply assistant text'
        'old-prompt user text'
    ) -join "`n"
    $turns = ConvertFrom-ClaudeTranscript ([IO.File]::ReadAllText((Join-Path $Here 'attribution.jsonl'))) 'attribution' 'claude' ''
    $got = @(foreach ($line in $turns) {
            $turn = $script:FunesJson.DeserializeObject($line)
            $blocks = @(foreach ($b in $turn['blocks']) { $b['block_type'] + $(if ($b['tool_name']) { ':' + $b['tool_name'] }) }) -join ','
            "$($turn['turn_uuid']) $($turn['role']) $blocks"
        }) -join "`n"
    if ($got -cne $want) { Fail "a turn has the wrong role or block type: $(Show-Difference $want $got)" }
} finally {
    Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output 'claude converter: ok'
