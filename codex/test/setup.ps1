# setup.sh, for setup.ps1: `setup.ps1 add` installs the plugin carrying the skill and the hooks,
# leaves the memory in a file beside its script, and registers the MCP server with Codex;
# `setup.ps1 remove` takes the registrations back. Run as funes runs it: by Windows PowerShell,
# from the bundle's place in the registry, with the contract's environment, against a `codex` that
# only records what it is asked.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File codex/test/setup.ps1

$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
$Bundle = Split-Path -Parent $Here
. (Join-Path $Here 'fake.ps1')
. (Join-Path $Bundle 'codex-plugin\plugins\funes\convert.ps1')

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('funes-codex-setup.' + [IO.Path]::GetRandomFileName())
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Fail([string]$message) {
    [Console]::Error.WriteLine("codex setup: $message")
    exit 1
}

function Write-Text([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, $utf8) }
function Read-Text([string]$path) { [IO.File]::ReadAllText($path) }
function Test-File([string]$path) { [IO.File]::Exists($path) }
function Set-Stamp([string]$path, [string]$when) { [IO.File]::SetLastWriteTimeUtc($path, [DateTime]::Parse($when, [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()) }

try {
    $userHome = Join-Path $tmp 'home'
    $bin = Join-Path $tmp 'bin'
    [void][IO.Directory]::CreateDirectory((Join-Path $userHome '.funes\agents'))
    New-FunesFake $bin @('codex')
    $env:USERPROFILE = $userHome
    $env:PATH = Get-FunesTestPath $bin
    $log = Join-Path $tmp 'cli.log'
    $env:FUNES_TEST_CLI_LOG = $log
    # The contract's environment, its paths spelled with `/` as funes hands them.
    $env:FUNES_BIN = 'funes'
    $env:FUNES_HOME = "$userHome\.funes".Replace('\', '/')
    $env:FUNES_AGENT_ID = 'codex'
    Remove-Item Env:FUNES_TEST_PAGES -ErrorAction SilentlyContinue
    # Codex answers for its own home; the default lands in the fake one.
    Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue

    $installed = Join-Path $userHome '.funes\agents\codex'
    Copy-Item -LiteralPath $Bundle -Destination $installed -Recurse
    $setup = Join-Path $installed 'setup.ps1'
    $marketplace = Join-Path $installed 'codex-plugin'
    $plugin = Join-Path $marketplace 'plugins\funes'
    $hooks = Join-Path $plugin 'hooks.json'
    $codexDir = Join-Path $userHome '.codex'
    $data = Join-Path $codexDir 'plugins\data\funes-huggingface'
    $spool = "$($env:FUNES_HOME)/spool/codex"

    # A rollout Codex already wrote, the converter's fixture, for the seed to find. 40 records it
    # makes no turn of follow the line that names the session, so the rollout runs longer than the
    # lines the seed reads to find its last turn.
    $tree = Join-Path $codexDir 'sessions\2026\09\25'
    [void][IO.Directory]::CreateDirectory($tree)
    $fixture = [IO.File]::ReadAllLines((Join-Path $Bundle 'codex-plugin\plugins\funes\test\session.jsonl'))
    $padding = @(1..40 | ForEach-Object { '{"type":"event_msg","payload":{"type":"token_count"}}' })
    Write-Text (Join-Path $tree 'rollout-seed.jsonl') ([string]::Join("`n", @($fixture[0]) + $padding + @($fixture | Select-Object -Skip 1)) + "`n")
    # A mark a hook of this bundle published before the add ran, with no rows of a walk beside it:
    # no mark is trusted until a walk has read every rollout.
    [void][IO.Directory]::CreateDirectory($data)
    Write-Text (Join-Path $data 'converted') ''

    function Invoke-Setup([string[]]$arguments) {
        $run = Invoke-FunesTestScript $setup $arguments
        if ($run.Code -ne 0) { Fail "setup.ps1 $arguments exited $($run.Code):`n$($run.Out)" }
        return $run.Out
    }

    # The hooks, as Codex reads them on Windows: each event's command for it.
    function Get-Hook([string]$event) {
        $all = $script:FunesJson.DeserializeObject((Read-Text $hooks))['hooks']
        if (-not $all.ContainsKey($event)) { return '' }
        return $all[$event][0]['hooks'][0]['commandWindows']
    }

    $out = Invoke-Setup @('add', 'acme/kb')
    if (-not $out.Contains('installed funes into Codex')) { Fail "add did not report: $out" }
    if (-not (Test-File (Join-Path $marketplace '.agents\plugins\marketplace.json'))) { Fail 'no marketplace manifest' }
    if (-not (Test-File (Join-Path $plugin '.codex-plugin\plugin.json'))) { Fail 'no plugin manifest' }
    # The skill Codex lists before loading any tool rides in the plugin.
    if (-not (Read-Text (Join-Path $plugin 'skills\funes\SKILL.md')).Contains('name: funes')) { Fail 'no skill in the plugin' }
    # Windows PowerShell runs the plugin's own script per turn, and the same script publishes at both
    # boundaries.
    $run = 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${PLUGIN_ROOT}/scripts/funes-index.ps1"'
    foreach ($case in @(@('Stop', $run), @('SessionStart', "$run --publish"), @('SessionEnd', "$run --publish"))) {
        if ((Get-Hook $case[0]) -cne $case[1]) { Fail "$($case[0]): $(Read-Text $hooks)" }
    }
    if ((Read-Text $hooks).Contains('acme/kb')) { Fail 'the memory is in the hook command' }
    if ((Read-Text (Join-Path $plugin 'scripts\memory')) -cne "acme/kb`n") { Fail 'no memory file' }
    if ((Read-Text (Join-Path $plugin 'scripts\spool')) -cne "$spool`n") { Fail 'the spool is not recorded' }
    $seeded = "$spool/rollout-seed.funes.jsonl"
    if (-not (Test-File $seeded)) { Fail 'the history was not seeded' }
    $mark = Join-Path $data 'converted'
    if (-not (Test-File $mark)) { Fail 'the walk left no mark' }
    # Trusting the hooks pins a hash of the plugin's contents, so the walk leaves nothing in the
    # plugin beyond what the hooks read.
    $listed = @(Get-ChildItem -LiteralPath (Join-Path $plugin 'scripts') | ForEach-Object { $_.Name } | Sort-Object) -join ' '
    if ($listed -cne 'funes-index.ps1 funes-index.sh memory spool') { Fail "the walk wrote beside the scripts: $listed" }
    $expected = "plugin marketplace add $marketplace`nplugin add funes@huggingface`n" +
        "mcp add funes --env HF_HUB_USER_AGENT_ORIGIN=funes; agent/codex -- funes mcp acme/kb`n"
    if ((Read-Text $log) -cne $expected) { Fail "codex was asked:`n$(Read-Text $log)" }

    # A re-run reads the rollouts written since the mark alone, and converts each unless its last
    # turn is one the local memory holds. With no `funes` to ask, as above, everything was converted.
    New-FunesFake $bin @('funes')
    $pages = Join-Path $tmp 'pages'
    [void][IO.Directory]::CreateDirectory($pages)
    $env:FUNES_TEST_PAGES = $pages
    # The rollout names its session on its first line, so the id is not the file's stem.
    $turns = [IO.File]::ReadAllLines((Join-Path $Bundle 'codex-plugin\plugins\funes\test\expected.funes.jsonl'))
    $id = $script:FunesJson.DeserializeObject($turns[-1])['session_id']
    $first = $script:FunesJson.DeserializeObject($turns[0])['ts']
    $last = $script:FunesJson.DeserializeObject($turns[-1])['ts']
    $arrow = [string][char]0x2192
    $dash = [string][char]0x2014
    # The listing, most recent first: another session, then, on the page the first one's trailer
    # names, the fixture's, ending on $until.
    function Set-Listing([string]$until) {
        Write-Text (Join-Path $pages '0') ("[2026-10-01T09:00:00.000Z $arrow 2026-10-01T09:30:00.000Z] codex /Users/me/other 4 turns other`n" +
            "  another ask`n---`n1 of 2 sessions $dash 1 older: continue with --offset 1, or narrow with --repo/--since/--until`n")
        Write-Text (Join-Path $pages '1') ("[$first $arrow $until] codex /Users/me/repo 7 turns $id`n" +
            "  the ask it opened with`n---`n1 of 2 sessions $dash the oldest match reached`n")
    }
    $older = "$spool/rollout-older.funes.jsonl"
    # The mark from a walk a while ago: the fixture's rollout was written since, and a copy of it no
    # listing names before.
    function Set-MarkAged { Set-Stamp $mark '2026-01-01T00:00:00Z' }
    Copy-Item -LiteralPath (Join-Path $tree 'rollout-seed.jsonl') -Destination (Join-Path $tree 'rollout-older.jsonl')
    Set-Stamp (Join-Path $tree 'rollout-older.jsonl') '2025-12-31T00:00:00Z'
    [IO.File]::SetLastWriteTimeUtc((Join-Path $tree 'rollout-seed.jsonl'), [DateTime]::UtcNow)
    Remove-Item -LiteralPath $seeded
    Set-Listing $last
    Set-MarkAged
    [void](Invoke-Setup @('add', 'acme/kb'))
    if (Test-File $older) { Fail 'a rollout older than the mark was read' }
    if (Test-File $seeded) { Fail 'a rollout whose last turn is indexed was converted again' }
    # The rows stay in the data directory, for the next walk.
    $rows = Read-Text (Join-Path $data 'indexed')
    if ($rows -cne "other 2026-10-01T09:30:00.000Z`n$id $last`n") { Fail "the memory's rows were not kept: $rows" }
    Set-Listing $first
    Set-MarkAged
    [void](Invoke-Setup @('add', 'acme/kb'))
    if (-not (Test-File $seeded)) { Fail 'a rollout that grew since its last indexed turn was not converted' }

    # A session the memory held at the last run and holds no more, as after a rebuild: every rollout
    # is read, the mark notwithstanding.
    Write-Text (Join-Path $pages '0') ("[2026-10-01T09:00:00.000Z $arrow 2026-10-01T09:30:00.000Z] codex /Users/me/other 4 turns other`n" +
        "  another ask`n---`n1 sessions`n")
    Set-MarkAged
    [void](Invoke-Setup @('add', 'acme/kb'))
    if (-not (Test-File $older)) { Fail 'a session gone from the memory left the rollouts older than the mark unread' }

    # A conversion that fails leaves the mark where it was, and no stamp behind. Held open with no
    # sharing, the rollout cannot be read.
    $unreadable = Join-Path $tree 'rollout-unreadable.jsonl'
    Write-Text $unreadable "{}`n"
    Set-Listing $last
    Set-MarkAged
    $lock = [IO.File]::Open($unreadable, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { [void](Invoke-Setup @('add', 'acme/kb')) } finally { $lock.Dispose() }
    if ([IO.File]::GetLastWriteTimeUtc($mark) -gt [DateTime]::Parse('2026-01-02T00:00:00Z').ToUniversalTime()) { Fail 'a failed conversion moved the mark' }
    # Matched by -like: Windows' own filter takes `converted.*` to match `converted` too.
    if (@(Get-ChildItem -LiteralPath $data | Where-Object { $_.Name -like 'converted.*' }).Count) { Fail 'the walk left its stamp behind' }
    Remove-Item -LiteralPath $unreadable

    # Re-run to bind the local memory: the file goes, and so do the boundary hooks.
    [void](Invoke-Setup @('add'))
    if (Test-File (Join-Path $plugin 'scripts\memory')) { Fail 'the memory file was left stale' }
    if (Get-Hook 'SessionEnd') { Fail 'a local install publishes' }

    # Remove: the registrations, the spool, the plugin's data directory, and never the memory.
    [void][IO.Directory]::CreateDirectory((Join-Path $userHome '.funes\memory\chunks.lance'))
    Write-Text (Join-Path $userHome '.funes\memory\chunks.lance\keep') 'memory'
    Write-Text $log ''
    [void](Invoke-Setup @('remove'))
    if (Test-Path -LiteralPath $spool) { Fail 'the spool stays' }
    if (Test-Path -LiteralPath $data) { Fail "the plugin's data directory stays" }
    if (Test-File (Join-Path $plugin 'scripts\spool')) { Fail 'the spool record stays' }
    if ((Read-Text (Join-Path $userHome '.funes\memory\chunks.lance\keep')) -cne 'memory') { Fail 'the memory was touched' }
    $expected = "mcp remove funes`nplugin remove funes@huggingface`nplugin marketplace remove huggingface`n"
    if ((Read-Text $log) -cne $expected) { Fail "codex was asked:`n$(Read-Text $log)" }
    # Already absent remains a successful no-op.
    [void](Invoke-Setup @('remove'))

    # With no `codex` on PATH, what is funes's own still goes, and the rest is spelled out.
    [void](Invoke-Setup @('add', 'acme/kb'))
    $env:PATH = Get-FunesTestPath ''
    $out = Invoke-Setup @('remove')
    if (-not $out.Contains('remove the registrations manually')) { Fail "no manual steps: $out" }
    if (Test-Path -LiteralPath $spool) { Fail 'the spool stays without codex' }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output 'codex setup: ok'
