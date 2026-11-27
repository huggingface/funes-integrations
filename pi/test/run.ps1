# Every test of the pi bundle on Windows, as run.sh is elsewhere: the converter, the extension's
# startup and the automation worker, on the JS runtime pi runs on, then `setup.ps1`, run as funes
# runs it.
#
# The converter's acceptance test: a real pi session, trimmed and secret-scanned, and the turns file
# it must produce. `expected.funes.jsonl` is what funes's own pi parser emitted while it had one, so
# a change here that moves a chunk id re-keys sessions users already hold.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File pi/test/run.ps1

$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
$node = (Get-Command node -CommandType Application | Select-Object -First 1).Source
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$out = Join-Path ([IO.Path]::GetTempPath()) ('funes-pi-test.' + [IO.Path]::GetRandomFileName())

function Invoke-Test([string]$what, [string]$exe, [string[]]$arguments) {
    & $exe @arguments
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("pi ${what}: failed (see above)")
        exit 1
    }
}

try {
    Invoke-Test 'converter' $node @((Join-Path $Here '..\convert.mjs'), (Join-Path $Here 'session.jsonl'), $out)
    $want = [IO.File]::ReadAllText((Join-Path $Here 'expected.funes.jsonl'))
    if ([IO.File]::ReadAllText((Join-Path $out 'session.funes.jsonl')) -cne $want) {
        [Console]::Error.WriteLine('pi converter: output changed')
        exit 1
    }
    # To the second: the runtime stamps to the millisecond, and ordering the spool needs no more.
    Invoke-Test "converter's stamp" $node @((Join-Path $Here 'same-second.mjs'), (Join-Path $out 'session.funes.jsonl'), (Join-Path $Here 'session.jsonl'))
    Write-Output 'pi converter: ok'

    # The session pi is writing, converted as it grows: what a whole conversion writes, at every step.
    Invoke-Test 'converter, live' $node @((Join-Path $Here 'live.mjs'), (Join-Path $out 'live'))
    Write-Output 'pi converter, live: ok'

    # The extension's startup, run as pi runs it: node strips the types itself from 22.18 on.
    Invoke-Test 'startup' $node @('--experimental-strip-types', (Join-Path $Here 'startup.mjs'))
    Write-Output 'pi startup: ok'

    Invoke-Test 'setup' $powershell @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Here 'setup.ps1'))
    Invoke-Test 'index' $node @((Join-Path $Here 'index.mjs'))
} finally {
    Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
}
