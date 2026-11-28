# funes-codex

A Codex plugin that gives Codex the funes read tools and keeps the memory current as you work.

Codex has an MCP client, so the read tools are `funes mcp` registered with `codex mcp add`: a
session sees whatever `tools/list` returns, the surface of the funes binary on PATH. Codex has a
plugin system, so the automation is one plugin at `~/.funes/agents/codex/codex-plugin` — a
marketplace root whose one plugin is `plugins/funes` — registered with
`codex plugin marketplace add` + `codex plugin add`. It carries the hooks and a small skill, which
is what lets Codex recognize funes as memory before it loads any of its tools. Codex writes its own
`config.toml` — funes never does — and nothing of funes's goes into Codex's own `hooks.json`.
`Stop` indexes the turn just completed. With a memory bound, `SessionEnd` and `SessionStart`
publish, and so does a turn once the last push is an hour old. How the hooks work is in this
repository's [README](../README.md#how-the-bundles-automate).

**Codex runs a hook only once you have trusted it.** After installing, run `/hooks` in Codex and
review them. Until then Codex skips them and nothing is indexed or published
([Codex docs](https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks)). Trusting them pins a
hash of the plugin's whole contents, checked before each run, so the review is due again after any
change to a funes hook or to the memory bound, and never because the hooks ran: what they write
(their log, the mark of their sweeps) goes in the directory Codex keeps for the plugin's data,
`~/.codex/plugins/data/funes-huggingface`, outside the plugin.

## Platforms

Officially supported on macOS and Linux, WSL2 included.

## Install

Once `funes` is on your PATH:

```sh
funes add codex
```

funes installs the plugin from its published release and brings it to the newest one on every run;
`funes add codex --from ./codex` installs this checkout's copy, which then runs as installed until
named again. A Codex too old to have plugins stops the install rather than leaving it silently
unpublished.

`funes add codex` also converts the rollouts Codex has already written. It shares a mark with the
hooks' sweeps, so a re-add reads only the rollouts written since the last of either, and leaves out
each one whose last turn the local memory holds, as its `funes sessions` row says (funes 1.9.0 and
newer). Those rows are kept with the mark, in the plugin's data directory. A session listed there
and gone from the memory since has the whole history read again.

An install from before the plugin is cleared on sight: its skill and scripts go, and its entries
come out of Codex's own `hooks.json` — hooks of your own in that file stay, and the file goes only
once nothing is left in it. Without `jq` to do that, the file is left as it is and named.

## Remove

```sh
funes remove codex
```

Removes the plugin, its marketplace registration, the MCP registration, the skill, and the
plugin's data directory, and clears an install from before the plugin the same way. Your memory and
Codex's own rollouts are untouched.

## Requirements

- `funes` on `PATH` (set `FUNES_BIN` to override the binary path).
- `codex` on `PATH`, with plugins; without it the files are installed and the commands to register
  them printed.
- A stock `jq`, 1.6 or newer, and 1.7 or newer on Windows, where an older one writes every line
  with CRLF and has no `--binary` to stop it: the converter is jq, and there is nothing to capture
  without it. macOS 15 and newer ship one; elsewhere `apt install jq`, `dnf install jq`,
  `apk add jq`, and on Windows `winget install jqlang.jq`.
  `funes add codex` checks that the jq on PATH converts a rollout the way funes reads it before it
  installs anything.
- On Windows, [Git for Windows](https://gitforwindows.org): funes runs `setup` with its shell, and
  the hooks' command is `sh …`, which needs that shell on the `PATH` Codex runs it with.
- A funes memory the binary can read — local, or a live `hf://` remote (needs network + an HF
  token for a private remote). Which one is funes's to bind:
  [docs/add.md](https://github.com/huggingface/funes/blob/main/docs/add.md#binding-a-memory).

## Converting by hand

The hooks' converter also converts rollouts they never saw, such as an archive or a colleague's
export. It turns one rollout into a turns file, with the session and turn ids the hooks give it,
and prints to stdout when it is given no output path. It needs jq:

```sh
~/.funes/agents/codex/codex-plugin/plugins/funes/convert <rollout.jsonl> [out.funes.jsonl]
```

In this checkout it is `codex/codex-plugin/plugins/funes/convert`. Convert into a directory of your
own, then run `funes index` on that directory.
