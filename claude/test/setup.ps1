# setup.sh, for setup.ps1: `setup.ps1 add` installs the skill and hooks plugin, leaves the memory
# in a file beside its script, and registers both surfaces with Claude; `setup.ps1 remove` takes
# them back, a pre-registry install with them, and never the memory. Run as funes runs it: by
# Windows PowerShell, from the bundle's place in the registry, with the contract's environment,
# against a `claude` that only records what it is asked.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File claude/test/setup.ps1

$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
$Bundle = Split-Path -Parent $Here
. (Join-Path $Here 'fake.ps1')
. (Join-Path $Bundle 'claude-plugin\funes\convert.ps1')

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('funes-claude-setup.' + [IO.Path]::GetRandomFileName())
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Fail([string]$message) {
    [Console]::Error.WriteLine("claude setup: $message")
    exit 1
}

function Write-Text([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, $utf8) }
function Read-Text([string]$path) { [IO.File]::ReadAllText($path) }
function Test-File([string]$path) { [IO.File]::Exists($path) }
function Set-Stamp([string]$path, [string]$when) { [IO.File]::SetLastWriteTimeUtc($path, [DateTime]::Parse($when, [Globalization.CultureInfo]::InvariantCulture)) }

try {
    $userHome = Join-Path $tmp 'home'
    $bin = Join-Path $tmp 'bin'
    [void][IO.Directory]::CreateDirectory((Join-Path $userHome '.funes\agents'))
    New-FunesFake $bin @('claude')
    $env:USERPROFILE = $userHome
    $env:PATH = Get-FunesTestPath $bin
    $log = Join-Path $tmp 'cli.log'
    $env:FUNES_TEST_CLI_LOG = $log
    # The contract's environment, its paths spelled with `/` as funes hands them.
    $env:FUNES_BIN = 'funes'
    $env:FUNES_HOME = "$userHome\.funes".Replace('\', '/')
    $env:FUNES_AGENT_ID = 'claude'
    Remove-Item Env:FUNES_TEST_PAGES -ErrorAction SilentlyContinue
    # Claude Code's transcripts live under its config directory, wherever the user put it: the
    # converter's fixture, for the seed to find, behind 40 records it makes no turn of, so the
    # transcript runs longer than the lines the seed reads to find its last turn.
    $env:CLAUDE_CONFIG_DIR = Join-Path $tmp 'claude-config'
    $tree = Join-Path $env:CLAUDE_CONFIG_DIR 'projects\-Users-me-repo'
    [void][IO.Directory]::CreateDirectory($tree)
    $fixture = Join-Path $Bundle 'claude-plugin\funes\test'
    $snapshots = [string]::Join('', @(1..40 | ForEach-Object { "{`"type`":`"file-history-snapshot`",`"snapshot`":{}}`n" }))
    Write-Text (Join-Path $tree 'session.jsonl') ($snapshots + (Read-Text (Join-Path $fixture 'session.jsonl')))
    # The journal a workflow keeps beside its sub-agents: records the converter makes no turn of.
    $journal = Join-Path $tree 'session\subagents\workflows\wf_1\journal.jsonl'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $journal))
    Write-Text $journal ("{`"type`":`"started`",`"agentId`":`"agent-1`",`"key`":`"review`"}`n" +
        "{`"type`":`"result`",`"agentId`":`"agent-1`",`"key`":`"review`",`"result`":`"ok`"}`n")

    $installed = Join-Path $userHome '.funes\agents\claude'
    Copy-Item -LiteralPath $Bundle -Destination $installed -Recurse
    $setup = Join-Path $installed 'setup.ps1'
    $plugin = Join-Path $installed 'claude-plugin'
    $scripts = Join-Path $plugin 'funes\scripts'
    $hooks = Join-Path $plugin 'funes\hooks\hooks.json'
    $spool = "$($env:FUNES_HOME)/spool/claude"

    function Invoke-Setup([string[]]$arguments, [switch]$MayFail) {
        $run = Invoke-FunesTestScript $setup $arguments
        if ($run.Code -ne 0 -and -not $MayFail) { Fail "setup.ps1 $arguments exited $($run.Code):`n$($run.Out)" }
        return $run.Out
    }

    # The hooks, as Claude Code reads them: each event's command and arguments.
    function Get-Hook([string]$event) {
        $all = $script:FunesJson.DeserializeObject((Read-Text $hooks))['hooks']
        if (-not $all.ContainsKey($event)) { return '' }
        $hook = $all[$event][0]['hooks'][0]
        return $hook['command'] + ' ' + [string]::Join(' ', $hook['args'])
    }

    # Bound to a memory.
    $out = Invoke-Setup @('add', 'acme/kb')
    if (-not $out.Contains('installed funes into Claude Code')) { Fail "add did not report: $out" }
    if (-not (Test-File (Join-Path $plugin '.claude-plugin\marketplace.json'))) { Fail 'no marketplace manifest' }
    if (-not (Test-File (Join-Path $plugin 'funes\.claude-plugin\plugin.json'))) { Fail 'no plugin manifest' }
    # The skill Claude loads from the plugin rides beside its hooks.
    if (-not (Read-Text (Join-Path $plugin 'funes\skills\funes\SKILL.md')).Contains('name: funes')) { Fail 'no skill in the plugin' }
    if (-not (Test-File (Join-Path $scripts 'funes-index.ps1'))) { Fail 'no hook script' }
    # Windows PowerShell runs the plugin's own script per turn and for a sub-agent, the same script
    # publishes at both boundaries, and no shell stands between.
    $run = 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ${CLAUDE_PLUGIN_ROOT}/scripts/funes-index.ps1'
    foreach ($case in @(@('Stop', $run), @('SubagentStop', $run), @('SessionStart', "$run --publish"), @('SessionEnd', "$run --publish"))) {
        if ((Get-Hook $case[0]) -cne $case[1]) { Fail "$($case[0]): $(Read-Text $hooks)" }
    }
    # The memory rides in a file, not the hook command, so the hooks stay a static file.
    if ((Read-Text $hooks).Contains('acme/kb')) { Fail 'the memory is in the hook command' }
    if ((Read-Text (Join-Path $scripts 'memory')) -cne "acme/kb`n") { Fail 'no memory file' }
    if ((Read-Text (Join-Path $scripts 'spool')) -cne "$spool`n") { Fail "the spool is not recorded: $(Read-Text (Join-Path $scripts 'spool'))" }
    $seeded = "$spool/session.funes.jsonl"
    if (-not (Test-File $seeded)) { Fail 'the history was not seeded' }
    if (Test-File "$spool/journal.funes.jsonl") { Fail "a workflow's journal was converted" }
    $mark = Join-Path $scripts 'converted'
    if (-not (Test-File $mark)) { Fail 'the walk left no mark' }
    $expected = "plugin marketplace add $plugin`nplugin uninstall funes@huggingface`nplugin install funes@huggingface`n" +
        "mcp remove funes`nmcp add funes -s user -e HF_HUB_USER_AGENT_ORIGIN=funes; agent/claude -- funes mcp acme/kb`n"
    if ((Read-Text $log) -cne $expected) { Fail "claude was asked:`n$(Read-Text $log)" }

    # A re-run reads the transcripts written since the mark alone, and converts each unless its last
    # turn is one the local memory holds. With no `funes` to ask, as above, everything was converted.
    New-FunesFake $bin @('funes')
    $pages = Join-Path $tmp 'pages'
    [void][IO.Directory]::CreateDirectory($pages)
    $env:FUNES_TEST_PAGES = $pages
    $turns = [IO.File]::ReadAllLines((Join-Path $fixture 'expected.funes.jsonl'))
    $id = $script:FunesJson.DeserializeObject($turns[-1])['session_id']
    $first = $script:FunesJson.DeserializeObject($turns[0])['ts']
    $last = $script:FunesJson.DeserializeObject($turns[-1])['ts']
    $arrow = [string][char]0x2192
    $dash = [string][char]0x2014
    # The listing, most recent first: another session, then, on the page the first one's trailer
    # names, the fixture's, ending on $until.
    function Set-Listing([string]$until) {
        Write-Text (Join-Path $pages '0') ("[2026-10-01T09:00:00.000Z $arrow 2026-10-01T09:30:00.000Z] claude /Users/me/other 4 turns other`n" +
            "  another ask`n---`n1 of 2 sessions $dash 1 older: continue with --offset 1, or narrow with --repo/--since/--until`n")
        Write-Text (Join-Path $pages '1') ("[$first $arrow $until] claude /Users/me/repo 5 turns $id`n" +
            "  the ask it opened with`n---`n1 of 2 sessions $dash the oldest match reached`n")
    }
    $older = "$spool/older.funes.jsonl"
    # The mark from a walk a while ago: the fixture's transcript was written since, and a copy of it
    # no listing names before.
    function Set-MarkAged { Set-Stamp $mark '2026-01-01T00:00:00Z' }
    Copy-Item -LiteralPath (Join-Path $tree 'session.jsonl') -Destination (Join-Path $tree 'older.jsonl')
    Set-Stamp (Join-Path $tree 'older.jsonl') '2025-12-31T00:00:00Z'
    [IO.File]::SetLastWriteTimeUtc((Join-Path $tree 'session.jsonl'), [DateTime]::UtcNow)
    Remove-Item -LiteralPath $seeded
    Set-Listing $last
    Set-MarkAged
    [void](Invoke-Setup @('add', 'acme/kb'))
    if (Test-File $older) { Fail 'a transcript older than the mark was read' }
    if (Test-File $seeded) { Fail 'a transcript whose last turn is indexed was converted again' }
    if (Test-File "$spool/journal.funes.jsonl") { Fail "a workflow's journal newer than the mark was converted" }
    # The rows stay beside the scripts, for the converter.
    $rows = Read-Text (Join-Path $scripts 'indexed')
    if ($rows -cne "other 2026-10-01T09:30:00.000Z 4`n$id $last 5`n") { Fail "the memory's rows were not kept: $rows" }
    Set-Listing $first
    Set-MarkAged
    [void](Invoke-Setup @('add', 'acme/kb'))
    if (-not (Test-File $seeded)) { Fail 'a transcript that grew since its last indexed turn was not converted' }

    # A session the memory held at the last run and holds no more, as after a rebuild: every
    # transcript is read, the mark notwithstanding.
    Write-Text (Join-Path $pages '0') ("[2026-10-01T09:00:00.000Z $arrow 2026-10-01T09:30:00.000Z] claude /Users/me/other 4 turns other`n" +
        "  another ask`n---`n1 sessions`n")
    Set-MarkAged
    [void](Invoke-Setup @('add', 'acme/kb'))
    if (-not (Test-File $older)) { Fail 'a session gone from the memory left the transcripts older than the mark unread' }

    # A conversion that fails leaves the mark where it was, and no stamp behind. Held open with no
    # sharing, the transcript cannot be read.
    $unreadable = Join-Path $tree 'unreadable.jsonl'
    Write-Text $unreadable "{}`n"
    Set-Listing $last
    Set-MarkAged
    $lock = [IO.File]::Open($unreadable, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { [void](Invoke-Setup @('add', 'acme/kb')) } finally { $lock.Dispose() }
    if ([IO.File]::GetLastWriteTimeUtc($mark) -gt [DateTime]::Parse('2026-01-02T00:00:00Z').ToUniversalTime()) { Fail 'a failed conversion moved the mark' }
    # Matched by -like: Windows' own filter takes `converted.*` to match `converted` too.
    if (@(Get-ChildItem -LiteralPath $scripts | Where-Object { $_.Name -like 'converted.*' }).Count) { Fail 'the walk left its stamp behind' }
    Remove-Item -LiteralPath $unreadable

    # A funes before 1.9.0 opens a row on its day alone, with no stamp to tell how a session it lists
    # was numbered: that session is converted without the messages typed while Claude was working
    # (the fixture's last two turns), and one it does not list with them.
    function Set-DayListing([string]$session) {
        Write-Text (Join-Path $pages '0') ("[$($first.Substring(0, 10))] claude /Users/me/repo 5 turns $session`n  the ask it opened with`n---`n1 sessions`n")
    }
    Remove-Item -LiteralPath $seeded
    Set-DayListing $id
    [void](Invoke-Setup @('add', 'acme/kb'))
    if ([IO.File]::ReadAllLines($seeded).Count -ne 3) { Fail 'a session listed with no span took its queued messages' }
    Remove-Item -LiteralPath $seeded
    Set-DayListing 'other'
    [void](Invoke-Setup @('add', 'acme/kb'))
    if ([IO.File]::ReadAllLines($seeded).Count -ne 5) { Fail 'a session no listing names left its queued messages out' }

    # Re-run to bind the local memory: the file goes, and so do the boundary hooks.
    [void](Invoke-Setup @('add'))
    if (Test-File (Join-Path $scripts 'memory')) { Fail 'the memory file was left stale' }
    if (Get-Hook 'SessionEnd') { Fail 'a local install publishes' }

    # Remove: the registrations, the spool, and never the memory.
    [void][IO.Directory]::CreateDirectory((Join-Path $userHome '.funes\memory\chunks.lance'))
    Write-Text (Join-Path $userHome '.funes\memory\chunks.lance\keep') 'memory'
    Write-Text (Join-Path $scripts 'pushed') ''
    Write-Text $log ''
    [void](Invoke-Setup @('remove'))
    if (Test-Path -LiteralPath $spool) { Fail 'the spool stays' }
    foreach ($name in 'spool', 'indexed', 'converted', 'pushed') {
        if (Test-File (Join-Path $scripts $name)) { Fail "the $name record stays" }
    }
    if ((Read-Text (Join-Path $userHome '.funes\memory\chunks.lance\keep')) -cne 'memory') { Fail 'the memory was touched' }
    $expected = "mcp remove funes -s user`nplugin uninstall funes@huggingface`nplugin marketplace remove huggingface`n"
    if ((Read-Text $log) -cne $expected) { Fail "claude was asked:`n$(Read-Text $log)" }
    # Already absent remains a successful no-op.
    [void](Invoke-Setup @('remove'))

    # With no `claude` on PATH, what is funes's own still goes, and the rest is spelled out.
    [void](Invoke-Setup @('add', 'acme/kb'))
    $env:PATH = Get-FunesTestPath ''
    $out = Invoke-Setup @('remove')
    if (-not $out.Contains('remove the registrations manually')) { Fail "no manual steps: $out" }
    if (Test-Path -LiteralPath $spool) { Fail 'the spool stays without claude' }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output 'claude setup: ok'
