# Convert one Codex rollout into a funes turns file (docs/funes-jsonl.md): `convert` for Windows,
# run by Windows PowerShell 5.1, which every Windows has, where `convert` needs sh and jq. The two
# make the same turns, byte for byte, which the same fixtures check.
#
#   convert.ps1 <rollout.jsonl> [<out.funes.jsonl>]
#
# With no output path the turns go to stdout; with one, they are written through a temporary file
# in the same directory and renamed, so a reader never sees a partial file.
#
# Dot-sourced, the script only defines its functions, so setup.ps1 and the hook convert many
# rollouts in one process. The file is ASCII: Windows PowerShell reads a script without a
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

# The writer escapes, besides what JSON must, & ' < > and U+0085, U+2028 and U+2029, which jq
# writes as they are: each comes back. jq escapes DEL, which the writer leaves literal.
$script:FunesUnescapes = foreach ($c in 0x26, 0x27, 0x3c, 0x3e, 0x85, 0x2028, 0x2029) {
    , @([regex]::new('(?<!\\)((?:\\\\)*)\\u' + ('{0:x4}' -f $c)), ('${1}' + [char]$c))
}
$script:FunesDel = [string][char]0x7f
$script:FunesDelEscaped = '\u' + '007f'

# A string with at least one character outside Unicode White_Space, i.e. what Rust str::trim
# leaves behind.
$script:FunesNonBlank = [regex]::new('[^\t\n\x0b\f\r \x85\xa0' + [char]0x1680 + [char]0x2000 + '-' + [char]0x200a +
    [char]0x2028 + [char]0x2029 + [char]0x202f + [char]0x205f + [char]0x3000 + ']')

# Codex records hook feedback as user messages: a message made entirely of hook_prompt elements.
$script:CodexHookPrompt = [regex]::new('\A\s*<hook_prompt hook_run_id="[^"]*">[\s\S]*</hook_prompt>\s*\z')

# A value as compact JSON, as jq writes it.
function ConvertTo-FunesJson($v) {
    $s = $script:FunesJson.Serialize($v)
    if ($s.IndexOf('\u', [StringComparison]::Ordinal) -ge 0) {
        foreach ($u in $script:FunesUnescapes) { $s = $u[0].Replace($s, $u[1]) }
    }
    if ($s.IndexOf($script:FunesDel, [StringComparison]::Ordinal) -ge 0) {
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
# dropped: a transcript may carry a partial trailing write.
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
    $tmp = "$out.$PID.tmp"
    try {
        Write-FunesLines $tmp $lines
        [IO.File]::SetLastWriteTimeUtc($tmp, [IO.File]::GetLastWriteTimeUtc($src))
        if ([IO.File]::Exists($out)) { [IO.File]::Delete($out) }
        [IO.File]::Move($tmp, $out)
    } finally {
        if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) }
    }
}

# A block, its name and call id unset; a turn drops what is unset.
function New-CodexBlock([string]$type, [string]$text) {
    $o = $script:FunesDict::new()
    $o['block_type'] = $type
    $o['text'] = $text
    $o['tool_name'] = $null
    $o['tool_use_id'] = $null
    return $o
}

function Get-CodexStr($v) { if ($v -is [string]) { $v } else { $null } }

# Codex records hook feedback as user messages. A message made entirely of hook_prompt elements
# is system. Quoted feedback and feedback mixed with human text keep their recorded role.
function Test-CodexHookPrompt($p) {
    if ($p['role'] -cne 'user') { return $false }
    $c = $p['content']
    if (-not ($c -is [object[]]) -or $c.Length -eq 0) { return $false }
    foreach ($e in $c) {
        if (-not ($e -is $script:FunesDict) -or $e['type'] -cne 'input_text' -or -not ($e['text'] -is [string])) { return $false }
        if (-not $script:CodexHookPrompt.IsMatch($e['text'])) { return $false }
    }
    return $true
}

# A response item's payload as `role` and `blocks`, or $null when it makes no turn.
function ConvertTo-CodexItem($p) {
    $pt = $p['type']
    $blocks = $script:FunesList::new()
    if ($pt -ceq 'message') {
        $role = ''
        if (Test-CodexHookPrompt $p) { $role = 'system' } elseif ($p['role'] -is [string]) { $role = $p['role'] }
        $c = $p['content']
        if ($c -is [string]) {
            if ($script:FunesNonBlank.IsMatch($c)) { $blocks.Add((New-CodexBlock 'text' $c)) }
        } elseif ($c -is [object[]]) {
            foreach ($e in $c) {
                if (-not ($e -is $script:FunesDict) -or -not ($e['type'] -ceq 'input_text' -or $e['type'] -ceq 'output_text')) { continue }
                $t = $e['text']
                if ($t -is [string] -and $script:FunesNonBlank.IsMatch($t)) { $blocks.Add((New-CodexBlock 'text' $t)) }
            }
        }
    } elseif ($pt -ceq 'reasoning') {
        $role = 'assistant'
        $summary = $p['summary']
        if ($summary -is [object[]]) {
            $parts = [System.Collections.Generic.List[string]]::new()
            foreach ($e in $summary) {
                if ($e -is $script:FunesDict -and $e['type'] -ceq 'summary_text' -and $e['text'] -is [string]) { $parts.Add($e['text']) }
            }
            $t = [string]::Join("`n", $parts)
            if ($script:FunesNonBlank.IsMatch($t)) { $blocks.Add((New-CodexBlock 'thinking' $t)) }
        }
    } elseif ($pt -ceq 'function_call' -or $pt -ceq 'custom_tool_call') {
        # function_call carries its args as an "arguments" JSON string, custom_tool_call as a raw
        # "input" string; either passes through verbatim. A present but non-string field does not
        # fall through to the other one.
        $role = 'assistant'
        $a = $null
        if ($p.ContainsKey('arguments')) { $a = $p['arguments'] } elseif ($p.ContainsKey('input')) { $a = $p['input'] }
        if (-not ($a -is [string])) { $a = '{}' }
        $o = New-CodexBlock 'tool_use' $a
        $o['tool_name'] = Get-CodexStr $p['name']
        $o['tool_use_id'] = Get-CodexStr $p['call_id']
        $blocks.Add($o)
    } elseif ($pt -ceq 'function_call_output' -or $pt -ceq 'custom_tool_call_output') {
        # A tool output as text: a string verbatim, null or absent as empty, anything else as
        # compact JSON. The name is left to the call_id back-fill.
        $role = 'tool'
        $o = $p['output']
        if ($o -is [string]) { $t = $o } elseif ($null -eq $o) { $t = '' } else { $t = ConvertTo-FunesJson $o }
        if ($script:FunesNonBlank.IsMatch($t)) {
            $b = New-CodexBlock 'tool_result' $t
            $b['tool_use_id'] = Get-CodexStr $p['call_id']
            $blocks.Add($b)
        }
    } else {
        return $null
    }
    if ($blocks.Count -eq 0) { return $null }
    $item = $script:FunesDict::new()
    $item['role'] = $role
    $item['blocks'] = $blocks
    return $item
}

# A value with its unset fields dropped: funes omits None rather than writing null.
function Remove-CodexUnset($d) {
    $o = $script:FunesDict::new()
    foreach ($k in $d.get_Keys()) { if ($null -ne $d[$k]) { $o[$k] = $d[$k] } }
    return $o
}

# The turns of a rollout's text, as JSON lines.
function ConvertFrom-CodexRollout([string]$text, [string]$stem) {
    $recs = Read-FunesRecords $text
    # The session id when no session_meta line carries one: the file stem, as funes names a session
    # after its transcript.
    $sid = $null
    $cwd = $null
    foreach ($r in $recs) {
        if ($r['type'] -cne 'session_meta' -or -not ($r['payload'] -is $script:FunesDict)) { continue }
        $p = $r['payload']
        if ($null -eq $sid -and $p['id'] -is [string]) { $sid = $p['id'] }
        if ($null -eq $cwd -and $p['cwd'] -is [string]) { $cwd = $p['cwd'] }
    }
    if ($null -eq $sid) { $sid = $stem }

    $items = $script:FunesList::new()
    foreach ($r in $recs) {
        if ($r['type'] -cne 'response_item' -or -not ($r['payload'] -is $script:FunesDict)) { continue }
        $item = ConvertTo-CodexItem $r['payload']
        if ($null -eq $item) { continue }
        $ts = $r['timestamp']
        if ($ts -is [string]) { $item['ts'] = $ts } else { $item['ts'] = '' }
        $items.Add($item)
    }

    # Each tool_result takes the name of the tool_use with the same call_id, anywhere in the file,
    # last write wins: a turn must render from its own fields alone.
    $names = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($item in $items) {
        foreach ($b in $item['blocks']) {
            if ($b['block_type'] -ceq 'tool_use' -and $null -ne $b['tool_use_id']) { $names[$b['tool_use_id']] = $b['tool_name'] }
        }
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    for ($seq = 0; $seq -lt $items.Count; $seq++) {
        $item = $items[$seq]
        $blocks = $script:FunesList::new()
        foreach ($b in $item['blocks']) {
            if ($b['block_type'] -ceq 'tool_result' -and $null -eq $b['tool_name'] -and $null -ne $b['tool_use_id']) {
                $name = $null
                [void]$names.TryGetValue($b['tool_use_id'], [ref]$name)
                $b['tool_name'] = $name
            }
            $blocks.Add((Remove-CodexUnset $b))
        }
        $turn = $script:FunesDict::new()
        $turn['format'] = 1
        $turn['session_id'] = $sid
        if ($null -ne $cwd) { $turn['cwd'] = $cwd }
        $turn['turn_uuid'] = $sid + '-' + $seq
        $turn['seq'] = $seq
        $turn['ts'] = $item['ts']
        $turn['role'] = $item['role']
        $turn['blocks'] = $blocks
        $turn['harness'] = 'codex'
        $lines.Add((ConvertTo-FunesJson $turn))
    }
    return , $lines
}

# Convert one rollout, to `$out` when given, else to stdout. Throws when the rollout cannot be read
# or written.
function Convert-CodexRollout([string]$src, [string]$out) {
    $lines = ConvertFrom-CodexRollout (Read-FunesText $src) ([IO.Path]::GetFileNameWithoutExtension($src))
    if ($out) { Write-FunesTurns $out $lines $src } else { Write-FunesStdout $lines }
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    if ($args.Count -lt 1 -or $args.Count -gt 2) {
        [Console]::Error.WriteLine('usage: convert.ps1 <rollout.jsonl> [<out.funes.jsonl>]')
        exit 2
    }
    if (-not [IO.File]::Exists($args[0])) {
        [Console]::Error.WriteLine("convert: cannot read $($args[0])")
        exit 1
    }
    $out = ''
    if ($args.Count -eq 2) { $out = $args[1] }
    try {
        Convert-CodexRollout $args[0] $out
    } catch {
        [Console]::Error.WriteLine("convert: $($_.Exception.Message)")
        exit 1
    }
    exit 0
}
