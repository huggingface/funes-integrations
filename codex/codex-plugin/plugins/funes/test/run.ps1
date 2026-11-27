# The converter's acceptance test on Windows: what run.sh checks of `convert`, checked of
# convert.ps1 against the same fixtures, so the two converters make the same turns byte for byte.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File <plugin>/test/run.ps1

$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
$Convert = Join-Path (Split-Path -Parent $Here) 'convert.ps1'
. $Convert

$out = Join-Path ([IO.Path]::GetTempPath()) ('funes-codex-convert.' + [IO.Path]::GetRandomFileName())
[void][IO.Directory]::CreateDirectory($out)

function Fail([string]$message) {
    [Console]::Error.WriteLine("codex converter: $message")
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
        Fail "the turns file does not carry the rollout's own time"
    }
    if ((Invoke-Convert @($session)) -cne $want) { Fail 'the turns on stdout differ from the turns file' }

    # The first four turns were captured with Codex 0.169.0, a Stop hook and a local mock model
    # server. Paths and session metadata are normalized. Later turns cover multiple hooks and user
    # messages that quote or mix hook text.
    $want = "0 user`n1 assistant`n2 system`n3 assistant`n4 system`n5 user`n6 user"
    $turns = ConvertFrom-CodexRollout ([IO.File]::ReadAllText((Join-Path $Here 'attribution.jsonl'))) 'attribution'
    $got = @(foreach ($line in $turns) {
            $turn = $script:FunesJson.DeserializeObject($line)
            "$($turn['seq']) $($turn['role'])"
        }) -join "`n"
    if ($got -cne $want) { Fail "a turn has the wrong role: $(Show-Difference $want $got)" }
} finally {
    Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output 'codex converter: ok'
