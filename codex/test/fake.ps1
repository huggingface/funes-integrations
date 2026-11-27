# The programs the Windows tests stand in for, dot-sourced by them: New-FunesFake compiles one
# executable, with the C# compiler of the .NET Framework every Windows has, and copies it under
# each name it is given. Windows runs no script by its first line, and what setup.ps1 and the hooks
# start is a program, so the stand-ins are programs too. What one does goes by its name:
#
#   funes  with FUNES_TEST_PAGES set, `funes sessions --memory local ... --offset N` prints the file
#          N there; otherwise it appends `<HF_HUB_USER_AGENT_ORIGIN>: <arguments>` to
#          FUNES_TEST_CLI_LOG, and an index exits 75, as funes does when the memory is busy, while
#          `<log>.busy` exists
#   other  appends its arguments to FUNES_TEST_CLI_LOG
#
# The file is ASCII: Windows PowerShell reads a script without a byte-order mark in the system code
# page.

$FunesFakeSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

public static class FunesFake {
    static void Append(string path, string text) {
        // Stand-ins side by side share the log.
        for (int attempt = 0; ; attempt++) {
            try {
                using (var log = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.Read)) {
                    var bytes = new UTF8Encoding(false).GetBytes(text);
                    log.Write(bytes, 0, bytes.Length);
                }
                return;
            } catch (IOException) {
                if (attempt > 200) throw;
                Thread.Sleep(10);
            }
        }
    }

    public static int Main(string[] args) {
        string name = Path.GetFileNameWithoutExtension(Process.GetCurrentProcess().MainModule.FileName);
        string log = Environment.GetEnvironmentVariable("FUNES_TEST_CLI_LOG");
        string line = string.Join(" ", args);
        if (name == "funes") {
            string pages = Environment.GetEnvironmentVariable("FUNES_TEST_PAGES");
            if (!string.IsNullOrEmpty(pages)) {
                if (args.Length < 3 || args[0] != "sessions" || args[1] != "--memory" || args[2] != "local") return 1;
                string offset = "0";
                for (int i = 0; i + 1 < args.Length; i++) if (args[i] == "--offset") offset = args[i + 1];
                byte[] page = File.ReadAllBytes(Path.Combine(pages, offset));
                using (var stdout = Console.OpenStandardOutput()) stdout.Write(page, 0, page.Length);
                return 0;
            }
            if (log != null) Append(log, (Environment.GetEnvironmentVariable("HF_HUB_USER_AGENT_ORIGIN") ?? "") + ": " + line + "\n");
            if (args.Length > 0 && args[0] == "index" && log != null && File.Exists(log + ".busy")) return 75;
            return 0;
        }
        if (log != null) Append(log, line + "\n");
        return 0;
    }
}
'@

function New-FunesFake([string]$dir, [string[]]$names) {
    [void][IO.Directory]::CreateDirectory($dir)
    $exe = Join-Path $dir "$($names[0]).exe"
    Add-Type -TypeDefinition $FunesFakeSource -Language CSharp -OutputType ConsoleApplication -OutputAssembly $exe
    foreach ($name in $names | Select-Object -Skip 1) { Copy-Item -LiteralPath $exe -Destination (Join-Path $dir "$name.exe") -Force }
}

# A program run to its end, its output read as UTF-8: what it printed, and how it exited.
function Invoke-FunesTestProgram([string]$exe, [string[]]$arguments, [string]$stdin) {
    $info = [System.Diagnostics.ProcessStartInfo]::new($exe)
    $info.Arguments = [string]::Join(' ', @($arguments | ForEach-Object { if ($_ -match '[\s"]' -or -not $_) { '"' + $_ + '"' } else { $_ } }))
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $info.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    $process = [System.Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if ($stdin) {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($stdin)
        $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    }
    $process.StandardInput.Close()
    $process.WaitForExit()
    return [pscustomobject]@{ Code = $process.ExitCode; Out = $stdout.Result + $stderr.Result }
}

# A script run as funes runs a setup, and an agent its hooks: by Windows PowerShell, from its file.
function Invoke-FunesTestScript([string]$script, [string[]]$arguments, [string]$stdin) {
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Invoke-FunesTestProgram $powershell (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script) + $arguments) $stdin
}

# The PATH a test runs under: its stand-ins, and Windows' own directories, where Windows PowerShell
# is; nothing a developer installed.
function Get-FunesTestPath([string]$bin) {
    $system = Join-Path $env:SystemRoot 'System32'
    $paths = @($system, $env:SystemRoot, (Join-Path $system 'WindowsPowerShell\v1.0'))
    if ($bin) { $paths = @($bin) + $paths }
    return [string]::Join(';', $paths)
}
