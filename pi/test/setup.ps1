# setup.sh, for setup.ps1: `setup.ps1 add` registers the bundle with pi as an extension and leaves
# the memory in the file index.ts reads; `setup.ps1 remove` unregisters it. Run as funes runs it: by
# Windows PowerShell, from the bundle's place in the registry, with the contract's environment,
# against a `pi` that only records what it is asked.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File pi/test/setup.ps1

$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
$Bundle = Split-Path -Parent $Here
. (Join-Path $Here 'fake.ps1')

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('funes-pi-setup.' + [IO.Path]::GetRandomFileName())
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Fail([string]$message) {
    [Console]::Error.WriteLine("pi setup: $message")
    exit 1
}

function Write-Text([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, $utf8) }
function Read-Text([string]$path) { [IO.File]::ReadAllText($path) }
function Test-File([string]$path) { [IO.File]::Exists($path) }

try {
    $userHome = Join-Path $tmp 'home'
    $bin = Join-Path $tmp 'bin'
    [void][IO.Directory]::CreateDirectory((Join-Path $userHome '.funes\agents'))
    New-FunesFake $bin @('pi')
    # The JS runtime the seed converts with, found before PATH is cut down to the fakes.
    $node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $node) { Fail 'no node to seed with' }
    $env:USERPROFILE = $userHome
    $env:PATH = (Get-FunesTestPath $bin) + ';' + (Split-Path -Parent $node.Source)
    $log = Join-Path $tmp 'cli.log'
    $env:FUNES_TEST_CLI_LOG = $log
    # The contract's environment, its paths spelled with `/` as funes hands them.
    $env:FUNES_BIN = 'funes'
    $env:FUNES_HOME = "$userHome\.funes".Replace('\', '/')
    $env:FUNES_AGENT_ID = 'pi'
    Remove-Item Env:PI_CODING_AGENT_DIR, Env:PI_CODING_AGENT_SESSION_DIR -ErrorAction SilentlyContinue
    # A session pi already wrote, the converter's fixture, for the seed to find.
    $sessions = Join-Path $userHome '.pi\agent\sessions'
    [void][IO.Directory]::CreateDirectory((Join-Path $sessions '--Users-me-repo--'))
    Copy-Item -LiteralPath (Join-Path $Bundle 'test\session.jsonl') -Destination (Join-Path $sessions '--Users-me-repo--\session.jsonl')

    $dir = Join-Path $userHome '.funes\agents\pi'
    Copy-Item -LiteralPath $Bundle -Destination $dir -Recurse
    $setup = Join-Path $dir 'setup.ps1'
    $spool = "$($env:FUNES_HOME)/spool/pi"

    function Invoke-Setup([string[]]$arguments) {
        $run = Invoke-FunesTestScript $setup $arguments
        if ($run.Code -ne 0) { Fail "setup.ps1 $arguments exited $($run.Code):`n$($run.Out)" }
        return $run.Out
    }

    $out = Invoke-Setup @('add', 'acme/kb')
    if (-not $out.Contains('installed funes into pi')) { Fail "add did not report: $out" }
    if (-not (Test-File (Join-Path $dir 'index.ts'))) { Fail 'the extension itself is missing' }
    if ((Read-Text (Join-Path $dir 'memory')) -cne "acme/kb`n") { Fail 'no memory file for index.ts' }
    if ((Read-Text (Join-Path $dir 'spool')) -cne "$spool`n") { Fail 'the spool is not recorded' }
    if ((Read-Text (Join-Path $dir 'sessions')) -cne "$sessions`n") { Fail "the sessions root is not recorded: $(Read-Text (Join-Path $dir 'sessions'))" }
    if (-not (Test-File "$spool/session.funes.jsonl")) { Fail 'the history was not seeded' }
    if (-not (Test-File (Join-Path $dir 'scripts\funes-index.mjs'))) { Fail 'the automation worker is missing' }
    # The version gate, then the registration.
    $expected = "--version`ninstall $dir`n"
    if ((Read-Text $log) -cne $expected) { Fail "pi was asked:`n$(Read-Text $log)" }

    # Re-running binds the local memory: the file index.ts reads is gone, not left stale. And with no
    # JS runtime to seed with, the history is left for the extension to convert at its next start.
    $env:PATH = Get-FunesTestPath $bin
    Remove-Item -LiteralPath "$spool/session.funes.jsonl"
    $out = Invoke-Setup @('add')
    if (Test-File (Join-Path $dir 'memory')) { Fail 'the memory file was left stale' }
    if (-not $out.Contains('no JS runtime')) { Fail "the seed did not say it was left pending: $out" }
    if ((Read-Text (Join-Path $dir 'seed-pending')) -cne "$sessions`n") { Fail 'the history was not left for the extension' }

    Write-Text (Join-Path $dir 'scripts\pushed') ''
    Write-Text $log ''
    [void](Invoke-Setup @('remove'))
    foreach ($name in 'spool', 'sessions', 'seed-pending', 'scripts\pushed') {
        if (Test-File (Join-Path $dir $name)) { Fail "the $name record stays" }
    }
    if (Test-Path -LiteralPath $spool) { Fail 'the spool stays' }
    if ((Read-Text $log) -cne "remove $dir`n") { Fail "pi was asked:`n$(Read-Text $log)" }
    # Already absent remains a successful no-op.
    [void](Invoke-Setup @('remove'))

    # With no `pi` on PATH, what is funes's own still goes, and the rest is spelled out.
    [void](Invoke-Setup @('add', 'acme/kb'))
    $env:PATH = Get-FunesTestPath ''
    $out = Invoke-Setup @('remove')
    if (-not $out.Contains('remove the registration manually')) { Fail "no manual step: $out" }
    if (Test-Path -LiteralPath $spool) { Fail 'the spool stays without pi' }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output 'pi setup: ok'
