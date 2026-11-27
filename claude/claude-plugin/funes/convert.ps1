# Convert a Claude Code transcript into a funes turns file (docs/funes-jsonl.md): `convert` for
# Windows, run by Windows PowerShell 5.1, which every Windows has, where `convert` needs sh and jq.
# The two make the same turns, byte for byte, which the same fixtures check.
#
#   convert.ps1 [--indexed <rows>] <transcript.jsonl> [out.funes.jsonl]
#
# The transcript is ~/.claude/projects/<workdir>/<uuid>.jsonl, or a sub-agent's
# <uuid>/subagents/agent-<hash>.jsonl. Without an output path the turns go to stdout; with one
# they are written through a temporary file and renamed, so a reader never sees a partial file.
#
# The session id is the transcript's file stem and the harness facet is the bundle id. `<rows>` is
# what the memory holds, as `<session id> <stamp of its last indexed turn> <turn count>` lines, or
# the session id alone: a session listed there keeps the numbering it was indexed with.
#
# A turn's role says who wrote it: `user` the human (an answered question box included), `assistant`
# the model, `tool` the output of a call, and `system` Claude Code itself.
#
# Dot-sourced, the script only defines its functions, so setup.ps1 and the hook convert many
# transcripts in one process. The file is ASCII: Windows PowerShell reads a script without a
# byte-order mark in the system code page.

Add-Type -AssemblyName System.Web.Extensions

# .NET Framework's JSON reader and writer, which Windows PowerShell runs on. It keeps the case and
# the order of an object's keys. Collections it writes are made with ::new(): New-Object wraps what
# it makes, and the writer cannot read through the wrapper.
$script:FunesJson = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
$script:FunesJson.MaxJsonLength = [int]::MaxValue
$script:FunesJson.RecursionLimit = 100000
$script:FunesDict = [System.Collections.Generic.Dictionary[string, object]]
$script:FunesList = [System.Collections.Generic.List[object]]
$script:FunesUtf8 = [System.Text.UTF8Encoding]::new($false)

# The reader takes a string spelled "\/Date(...)\/" for a date. With its slashes unescaped it is
# the same string, which the reader takes for text.
$script:FunesDateSlash = [regex]::new('(?<!\\)(?<b>(?:\\\\)*)\\/')

# The writer escapes, besides what JSON must, & ' < > and U+0085, U+2028 and U+2029, which jq and
# serde_json write as they are: each comes back. jq escapes DEL where serde_json, which serialized
# the rows funes already holds, leaves it literal: a turns file is written as jq writes it, and the
# input of a call, whose serialization is itself the indexed text, as serde_json does.
$script:FunesUnescapes = foreach ($c in 0x26, 0x27, 0x3c, 0x3e, 0x85, 0x2028, 0x2029) {
    , @([regex]::new('(?<!\\)((?:\\\\)*)\\u' + ('{0:x4}' -f $c)), ('${1}' + [char]$c))
}
$script:FunesDel = [string][char]0x7f
$script:FunesDelEscaped = '\u' + '007f'

# A block whose text is only whitespace is dropped; the set is Unicode White_Space.
$script:FunesNonBlank = [regex]::new('[^\t\n\x0b\f\r \x85\xa0' + [char]0x1680 + [char]0x2000 + '-' + [char]0x200a +
    [char]0x2028 + [char]0x2029 + [char]0x202f + [char]0x205f + [char]0x3000 + ']')

# A value as compact JSON, as jq writes it, or as serde_json does with `$serde`.
function ConvertTo-FunesJson($v, [bool]$serde = $false) {
    $s = $script:FunesJson.Serialize($v)
    if ($s.IndexOf('\u', [StringComparison]::Ordinal) -ge 0) {
        foreach ($u in $script:FunesUnescapes) { $s = $u[0].Replace($s, $u[1]) }
    }
    if (-not $serde -and $s.IndexOf($script:FunesDel, [StringComparison]::Ordinal) -ge 0) {
        $s = $s.Replace($script:FunesDel, $script:FunesDelEscaped)
    }
    return $s
}

# A file's text, read while its writer may still hold it open.
function Read-FunesText([string]$path) {
    $stream = [System.IO.FileStream]::new($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        return [System.IO.StreamReader]::new($stream, $script:FunesUtf8, $true).ReadToEnd()
    } finally {
        $stream.Dispose()
    }
}

# Every line of a JSONL text that parses as a JSON object, in order. A line that does not parse is
# dropped the way a whole-file reader drops a partial trailing write.
function Read-FunesRecords([string]$text) {
    $records = $script:FunesList::new()
    foreach ($line in $text.Split([char]10)) {
        if ($line.Length -eq 0) { continue }
        if ($line.Contains('\/Date(')) { $line = $script:FunesDateSlash.Replace($line, '${b}/') }
        try { $r = $script:FunesJson.DeserializeObject($line) } catch { continue }
        if ($r -is $script:FunesDict) { $records.Add($r) }
    }
    return , $records
}

# Lines, as files spell them: LF-ended UTF-8 without a byte-order mark.
function Write-FunesLines([string]$path, $lines) {
    $text = ''
    if ($lines.Count) { $text = [string]::Join("`n", $lines) + "`n" }
    [IO.File]::WriteAllText($path, $text, $script:FunesUtf8)
}

function Write-FunesStdout($lines) {
    if (-not $lines.Count) { return }
    $bytes = $script:FunesUtf8.GetBytes([string]::Join("`n", $lines) + "`n")
    $out = [Console]::OpenStandardOutput()
    $out.Write($bytes, 0, $bytes.Length)
    $out.Flush()
}

# Lines into `$out` through a temporary file in its directory, stamped with the time of `$src`, so
# funes drains the spool newest session first rather than in the order the seed converted them.
# The suffix must not be `.jsonl`: one stray `.jsonl` file rejects a whole turns directory.
function Write-FunesTurns([string]$out, $lines, [string]$src) {
    $tmp = "$out.tmp.$PID"
    try {
        Write-FunesLines $tmp $lines
        [IO.File]::SetLastWriteTimeUtc($tmp, [IO.File]::GetLastWriteTimeUtc($src))
        if ([IO.File]::Exists($out)) { [IO.File]::Delete($out) }
        [IO.File]::Move($tmp, $out)
    } finally {
        if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) }
    }
}

function New-ClaudeBlock([string]$type, [string]$text) {
    $o = $script:FunesDict::new()
    $o['block_type'] = $type
    $o['text'] = $text
    return $o
}

# A content block as a funes block, or $null when it makes none.
function ConvertTo-ClaudeBlock($b) {
    $t = $b['type']
    if ($t -ceq 'text' -or $t -ceq 'thinking') {
        $x = $b[$t]
        if (-not ($x -is [string]) -or -not $script:FunesNonBlank.IsMatch($x)) { return $null }
        return (New-ClaudeBlock $t $x)
    }
    if ($t -ceq 'tool_use') {
        $arguments = $script:FunesDict::new()
        if ($b.ContainsKey('input')) { $arguments = $b['input'] }
        $o = New-ClaudeBlock 'tool_use' (ConvertTo-FunesJson $arguments $true)
        if ($b['name'] -is [string]) { $o['tool_name'] = $b['name'] }
        if ($b['id'] -is [string]) { $o['tool_use_id'] = $b['id'] }
        return $o
    }
    if ($t -ceq 'tool_result') {
        $c = $b['content']
        $x = ''
        if ($c -is [string]) {
            $x = $c
        } elseif ($c -is [object[]]) {
            $parts = [System.Collections.Generic.List[string]]::new()
            foreach ($e in $c) {
                if ($e -is $script:FunesDict) {
                    if ($e['type'] -ceq 'text') {
                        $text = $e['text']
                        if ($text -is [string]) { $parts.Add($text) } else { $parts.Add('') }
                    }
                } elseif ($e -is [string]) {
                    $parts.Add($e)
                }
            }
            $x = [string]::Join("`n", $parts)
        }
        if (-not $script:FunesNonBlank.IsMatch($x)) { return $null }
        $o = New-ClaudeBlock 'tool_result' $x
        if ($b['tool_use_id'] -is [string]) { $o['tool_use_id'] = $b['tool_use_id'] }
        return $o
    }
    return $null
}

function ConvertTo-ClaudeBlocks($content) {
    $blocks = $script:FunesList::new()
    if ($content -is [string]) {
        if ($script:FunesNonBlank.IsMatch($content)) { $blocks.Add((New-ClaudeBlock 'text' $content)) }
    } elseif ($content -is [object[]]) {
        foreach ($e in $content) {
            if ($e -is $script:FunesDict) {
                $o = ConvertTo-ClaudeBlock $e
                if ($null -ne $o) { $blocks.Add($o) }
            }
        }
    }
    return , $blocks
}

function Test-ClaudeMarker($v) {
    $v -is [string] -and $v.StartsWith('[Request interrupted', [StringComparison]::Ordinal)
}

# A user line Claude Code wrote itself: a nudge, a notification, a skill body, the compact recap, a
# message from another session, or the marker an interruption leaves. It is `system`, so funes never
# takes it for the words of the human. Claude Code flags each one but the marker, which only its
# text tells apart.
function Test-ClaudeHarnessWritten($r, $msg) {
    if ($r['isMeta'] -is [bool] -and $r['isMeta']) { return $true }
    if ($r['isCompactSummary'] -is [bool] -and $r['isCompactSummary']) { return $true }
    $origin = $r['origin']
    if ($origin -is $script:FunesDict) {
        $k = $origin['kind']
        if ($k -is [string] -and $k -cne '' -and $k -cne 'human') { return $true }
    }
    if ($null -eq $msg) { return $false }
    $c = $msg['content']
    if ($c -is [string]) { return (Test-ClaudeMarker $c) }
    if ($c -is [object[]]) {
        if ($c.Length -eq 0) { return $false }
        foreach ($e in $c) {
            if (-not ($e -is $script:FunesDict -and $e['type'] -ceq 'text')) { return $false }
            if (-not (Test-ClaudeMarker $e['text'])) { return $false }
        }
        return $true
    }
    return $false
}

# The turns of a transcript's text, as JSON lines.
function ConvertFrom-ClaudeTranscript([string]$text, [string]$sid, [string]$harness, [string]$rows) {
    $recs = Read-FunesRecords $text
    $cwd = $null
    foreach ($r in $recs) {
        if ($r['cwd'] -is [string]) { $cwd = $r['cwd']; break }
    }
    # An answered question box holds the decision of the human, though Claude Code returns it as the
    # tool_result of the AskUserQuestion call: it becomes their text. Any other line holding tool
    # output is `tool`.
    $asked = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($r in $recs) {
        $msg = $r['message']
        if (-not ($msg -is $script:FunesDict) -or -not ($msg['content'] -is [object[]])) { continue }
        foreach ($e in $msg['content']) {
            if ($e -is $script:FunesDict -and $e['type'] -ceq 'tool_use' -and $e['name'] -ceq 'AskUserQuestion' -and $e['id'] -is [string]) {
                [void]$asked.Add($e['id'])
            }
        }
    }

    # A line as a turn: a user or assistant message, or a message the user typed while Claude was
    # working, marked queued. Claude Code writes that one as a queued_command attachment in prompt
    # mode rather than a user line. A message from another session is queued the same way, so the
    # origin must be the human one, or absent (older versions write none). Its `rendered` field is
    # the system reminder that wraps the text, so only `prompt` is what they typed. A line whose
    # result records answers is a question box the human answered.
    $all = $script:FunesList::new()
    $queued = [System.Collections.Generic.List[bool]]::new()
    foreach ($r in $recs) {
        $rt = $r['type']
        $answered = $false
        $isQueued = $false
        if ($rt -ceq 'user' -or $rt -ceq 'assistant') {
            $msg = $r['message']
            if (-not ($msg -is $script:FunesDict)) { $msg = $null }
            $role = $rt
            if ($null -ne $msg -and $msg['role'] -is [string]) { $role = $msg['role'] }
            if ($rt -ceq 'user') {
                if (Test-ClaudeHarnessWritten $r $msg) { $role = 'system' }
            } elseif (($r['isApiErrorMessage'] -is [bool] -and $r['isApiErrorMessage']) -or ($null -ne $msg -and $msg['model'] -ceq '<synthetic>')) {
                # A reply Claude Code wrote in place of the model, such as an API error or "No
                # response requested.".
                $role = 'system'
            }
            $content = $null
            if ($null -ne $msg) { $content = $msg['content'] }
            $result = $r['toolUseResult']
            if ($result -is $script:FunesDict) {
                $answers = $result['answers']
                $answered = $answers -is $script:FunesDict -and $answers.get_Count() -gt 0
            }
        } elseif ($rt -ceq 'attachment') {
            $a = $r['attachment']
            if (-not ($a -is $script:FunesDict) -or $a['type'] -cne 'queued_command' -or $a['commandMode'] -cne 'prompt') { continue }
            $origin = $a['origin']
            if ($null -ne $origin -and -not ($origin -is $script:FunesDict -and $origin['kind'] -ceq 'human')) { continue }
            $role = 'user'
            $content = $a['prompt']
            $isQueued = $true
        } else {
            continue
        }
        $blocks = ConvertTo-ClaudeBlocks $content
        if ($answered) {
            for ($i = 0; $i -lt $blocks.Count; $i++) {
                $b = $blocks[$i]
                if ($b['block_type'] -ceq 'tool_result' -and $b.ContainsKey('tool_use_id') -and $asked.Contains($b['tool_use_id'])) {
                    $blocks[$i] = New-ClaudeBlock 'text' $b['text']
                }
            }
        }
        if ($blocks.Count -eq 0) { continue }
        if ($role -ceq 'user') {
            foreach ($b in $blocks) { if ($b['block_type'] -ceq 'tool_result') { $role = 'tool'; break } }
        }
        $turn = $script:FunesDict::new()
        $turn['format'] = 1
        $turn['session_id'] = $sid
        if ($null -ne $cwd) { $turn['cwd'] = $cwd }
        $uuid = $r['uuid']
        if ($uuid -is [string]) { $turn['turn_uuid'] = $uuid } else { $turn['turn_uuid'] = '' }
        if ($r['parentUuid'] -is [string]) { $turn['parent_uuid'] = $r['parentUuid'] }
        $turn['seq'] = 0
        $ts = $r['timestamp']
        if ($ts -is [string]) { $turn['ts'] = $ts } else { $turn['ts'] = '' }
        $turn['role'] = $role
        $turn['blocks'] = $blocks
        $turn['harness'] = $harness
        $all.Add($turn)
        $queued.Add($isQueued)
    }

    # A session the memory holds without its queued messages keeps that numbering, and never takes
    # them. Its row says so: the n-th turn counted without them carries the stamp of its last indexed
    # turn, where a session indexed with them has it on the n-th counted with them. With none before
    # that turn the two counts agree, and the session takes them. The count without them is read
    # first, so when both name a turn carrying the stamp, the session is one indexed without them. A
    # row with no stamp (funes before 1.9.0), or one neither count matches, leaves them out too.
    $without = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt $all.Count; $i++) { if (-not $queued[$i]) { $without.Add($i) } }
    $row = $null
    foreach ($line in $rows.Split([char]10)) {
        $fields = $line.Split(' ')
        if ($fields[0] -ceq $sid) { $row = $fields; break }
    }
    $takes = $false
    $n = 0
    if ($null -eq $row) {
        $takes = $true
    } elseif ($row.Length -eq 3 -and [int]::TryParse($row[2], [ref]$n) -and $n -ge 1) {
        if ($without.Count -ge $n -and $all[$without[$n - 1]]['ts'] -ceq $row[1]) {
            # Whether the n-th turn counted without them is the n-th counted with them, as JSON
            # compares: the same turn, or one alike in every field, its mark included.
            $w = $without[$n - 1]
            $takes = $w -eq $n - 1 -or (-not $queued[$n - 1] -and
                (ConvertTo-FunesJson $all[$w]) -ceq (ConvertTo-FunesJson $all[$n - 1]))
        } else {
            $takes = $all.Count -ge $n -and $all[$n - 1]['ts'] -ceq $row[1]
        }
    }
    $turns = $script:FunesList::new()
    for ($i = 0; $i -lt $all.Count; $i++) {
        if ($takes -or -not $queued[$i]) { $turns.Add($all[$i]) }
    }

    # tool_result.tool_name comes from the tool_use with the same id, whole file, last write wins,
    # so every emitted turn stands alone.
    $names = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($turn in $turns) {
        foreach ($b in $turn['blocks']) {
            if ($b['block_type'] -ceq 'tool_use' -and $b.ContainsKey('tool_use_id')) { $names[$b['tool_use_id']] = $b['tool_name'] }
        }
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $turns.Count; $i++) {
        $turn = $turns[$i]
        $turn['seq'] = $i
        $blocks = $turn['blocks']
        for ($j = 0; $j -lt $blocks.Count; $j++) {
            $b = $blocks[$j]
            if ($b['block_type'] -ceq 'tool_result' -and $b.ContainsKey('tool_use_id')) {
                $name = $null
                if ($names.TryGetValue($b['tool_use_id'], [ref]$name) -and $null -ne $name) {
                    $o = New-ClaudeBlock 'tool_result' $b['text']
                    $o['tool_name'] = $name
                    $o['tool_use_id'] = $b['tool_use_id']
                    $blocks[$j] = $o
                }
            }
        }
        $lines.Add((ConvertTo-FunesJson $turn))
    }
    return , $lines
}

# A transcript's file stem, which is its session's id.
function Get-ClaudeStem([string]$path) {
    $stem = [IO.Path]::GetFileName($path)
    if ($stem.EndsWith('.jsonl', [StringComparison]::Ordinal)) { $stem = $stem.Substring(0, $stem.Length - 6) }
    return $stem
}

# Convert one transcript, to `$out` when given, else to stdout, numbering a session the rows file
# `$rows` lists as the memory holds it. Throws when the transcript cannot be read or written.
function Convert-ClaudeTranscript([string]$src, [string]$out, [string]$rows) {
    $rowsText = ''
    if ($rows -and [IO.File]::Exists($rows)) { $rowsText = Read-FunesText $rows }
    $harness = 'claude'
    if ($env:FUNES_AGENT_ID) { $harness = $env:FUNES_AGENT_ID }
    $lines = ConvertFrom-ClaudeTranscript (Read-FunesText $src) (Get-ClaudeStem $src) $harness $rowsText
    if ($out) { Write-FunesTurns $out $lines $src } else { Write-FunesStdout $lines }
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    $argv = @($args)
    $rows = ''
    if ($argv.Count -ge 2 -and $argv[0] -ceq '--indexed') {
        $rows = $argv[1]
        $argv = @($argv | Select-Object -Skip 2)
    }
    if ($argv.Count -lt 1 -or $argv.Count -gt 2) {
        [Console]::Error.WriteLine('usage: convert.ps1 [--indexed <rows>] <transcript.jsonl> [out.funes.jsonl]')
        exit 2
    }
    if (-not [IO.File]::Exists($argv[0])) {
        [Console]::Error.WriteLine("convert: no such transcript: $($argv[0])")
        exit 1
    }
    $out = ''
    if ($argv.Count -eq 2) { $out = $argv[1] }
    try {
        Convert-ClaudeTranscript $argv[0] $out $rows
    } catch {
        [Console]::Error.WriteLine("convert: $($_.Exception.Message)")
        exit 1
    }
    exit 0
}
