// A stand-in for funes, for the tests that start it as a program: a JS body, run by the runtime the
// test runs on, behind a launcher the platform runs under funes's own name. On Linux and macOS the
// launcher is a shell script; Windows runs no script by its first line, so there it is a program,
// compiled once with the C# compiler of the .NET Framework every Windows has. Either hands the body
// its arguments and its standard streams, and exits as it does.
//
//   fakeFunes(dir, body[, name])   writes `<dir>/<name>.mjs` and the launcher, and returns its path
import { execFileSync } from "node:child_process";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const WINDOWS = process.platform === "win32";

// How the runtime the test runs on runs a script.
export function runtimeArgs(script) {
  return process.versions.deno ? ["run", "--allow-all", script] : [script];
}

// The launcher's source: it runs `<itself>.mjs` with the runtime FUNES_TEST_NODE names, quoting
// each argument as a Windows program reads it back.
const LAUNCHER = String.raw`
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

public static class FunesLauncher {
    static string Quote(string a) {
        if (a.Length > 0 && a.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return a;
        var quoted = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in a) {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') { quoted.Append('\\', slashes * 2 + 1).Append('"'); slashes = 0; continue; }
            quoted.Append('\\', slashes).Append(c);
            slashes = 0;
        }
        return quoted.Append('\\', slashes * 2).Append('"').ToString();
    }

    public static int Main(string[] args) {
        string script = Path.ChangeExtension(Process.GetCurrentProcess().MainModule.FileName, ".mjs");
        var line = new StringBuilder(Quote(script));
        foreach (string a in args) line.Append(' ').Append(Quote(a));
        var info = new ProcessStartInfo(Environment.GetEnvironmentVariable("FUNES_TEST_NODE"), line.ToString());
        info.UseShellExecute = false;
        using (var child = Process.Start(info)) {
            child.WaitForExit();
            return child.ExitCode;
        }
    }
}
`;

let compiled;
function launcher() {
  if (compiled) return compiled;
  const dir = mkdtempSync(join(tmpdir(), "funes-fake-"));
  process.on("exit", () => rmSync(dir, { recursive: true, force: true }));
  const windir = process.env.SystemRoot || process.env.WINDIR || "C:\\Windows";
  const csc = ["Framework64", "Framework"].map((d) => join(windir, "Microsoft.NET", d, "v4.0.30319", "csc.exe")).find(existsSync);
  if (!csc) throw new Error("no C# compiler of the .NET Framework 4 to build the funes stand-in with");
  writeFileSync(join(dir, "launcher.cs"), LAUNCHER);
  compiled = join(dir, "launcher.exe");
  execFileSync(csc, ["/nologo", "/target:exe", `/out:${compiled}`, join(dir, "launcher.cs")], { stdio: "pipe" });
  return compiled;
}

export function fakeFunes(dir, body, name = "funes") {
  mkdirSync(dir, { recursive: true });
  const script = join(dir, `${name}.mjs`);
  writeFileSync(script, body);
  if (WINDOWS) {
    process.env.FUNES_TEST_NODE = process.execPath;
    const exe = join(dir, `${name}.exe`);
    copyFileSync(launcher(), exe);
    return exe;
  }
  const path = join(dir, name);
  const argv = runtimeArgs(script).map((a) => `"${a}"`).join(" ");
  writeFileSync(path, `#!/bin/sh\nexec "${process.execPath}" ${argv} "$@"\n`);
  chmodSync(path, 0o755);
  return path;
}
