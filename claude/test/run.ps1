# Every test of the claude bundle on Windows, as run.sh is elsewhere: the converter, then
# `setup.ps1` and the hook worker, each run as funes and Claude Code run them, against fakes.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File claude/test/run.ps1

$ErrorActionPreference = 'Stop'
$bundle = Split-Path -Parent $PSScriptRoot
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
foreach ($test in 'claude-plugin\funes\test\run.ps1', 'test\setup.ps1', 'test\hooks.ps1') {
    & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $bundle $test)
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
