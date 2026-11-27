# funes-integrations

The agent integrations Hugging Face maintains for [funes](https://github.com/huggingface/funes) —
`claude`, `codex`, `hermes` and `pi` — and the catalog `funes add <id>` installs them from.
Integrations maintained by their authors live wherever their authors put them;
[COMMUNITY.md](COMMUNITY.md) is where they are listed.

## Layout

One directory per integration, each a bundle as funes's
[integration contract](https://github.com/huggingface/funes/blob/main/docs/add.md#the-integration-contract)
describes it: a `manifest.json`, a `setup` executable, whatever the integration needs beside them,
and its own tests under `test/`. What each one installs into its agent, which of its events it
hooks, and what it needs on the box is in its README; what they share is below.

`hf-traces/` is the one directory that is not an integration. It converts Hugging Face agent-traces
datasets, and installs nothing.

## How the bundles automate

Each bundle gives its agent the funes read tools: `funes mcp`, registered as an MCP server, or
fronted by the bundle where the agent has no MCP client. It keeps the memory current from the
agent's own events, converting the agent's sessions with a converter of its own:

- Per turn, it converts the session that just changed, and any other session changed since it last
  ran, into funes's spool, then runs `funes index --harness <id>`. A session whose own hook never
  fired (untrusted, timed out, a host that died mid-turn) is caught at the next turn. The index is
  time-boxed, so a backlog fills in a bounded step per turn.
- At the session boundaries, and only with a memory bound, it indexes, waiting out a per-turn run's
  lock, then pushes. It does so at the session's end and again at the next start, which catches up
  whatever a missed end left behind.
- With a memory bound, a turn pushes too once the last push is an hour old. A session can stop
  without its end ever firing (a conversation switched away, a window closed, a host
  disconnected), and the next start may never come on that host.

The work runs detached, so a hook returns in well under a second and never blocks the turn or trips
a timeout. The memory rides in a file of its own, so the hooks never change with it. At install,
`setup add` converts the sessions the agent has already written.

What funes guarantees around these (local-first indexing, one writer at a time, the secrets gate,
the wrong-memory guard) is in funes's
[automation docs](https://github.com/huggingface/funes/blob/main/docs/automation.md).

## What a bundle runs on

Each bundle's README states the platforms it officially supports. Two guidelines keep it working
on each of them:

- Use tools that work on every platform and that the agent already uses, such as its own runtime.
- Avoid adding dependencies, tools or packages: nothing should be installed for funes alone.

`setup` is the exception: funes runs it with a POSIX shell, as its
[integration contract](https://github.com/huggingface/funes/blob/main/docs/add.md#the-integration-contract)
describes.

## Converting by hand

Indexing an agent's history on a machine that never ran the automation — an archive, a colleague's
export — is the bundle's converter into a directory of your own, then `funes index` on that
directory, as funes's [add docs](https://github.com/huggingface/funes/blob/main/docs/add.md#converting-by-hand)
describe. Each converter is its bundle's own, and emits the session and turn ids the hooks do. How
to run it is in the bundle's README: [claude](claude/README.md#converting-by-hand),
[codex](codex/README.md#converting-by-hand), [hermes](hermes/README.md#converting-by-hand),
[pi](pi/README.md#converting-by-hand).

### Hugging Face agent-traces datasets

The Hub keeps a parquet copy of an agent-traces dataset on its `refs/convert/parquet` branch.
`hf-traces/convert.py` turns it into one turns file per session. It needs pyarrow, which `uv run`
installs from the script's own header:

```bash
hf download <org>/<repo> --repo-type dataset --revision refs/convert/parquet --local-dir traces
uv run hf-traces/convert.py traces ~/imports
funes index ~/imports
```

It maps a session as funes's own reader did when `funes index <org>/<repo>` read these datasets, so
a dataset a memory already holds keeps its turn ids and a re-import adds nothing. A session id that
is not a plain file name is reported and skipped.

## Developing

A working copy installs into funes straight from the checkout:

```sh
funes add pi --from ./pi
```

funes confirms at the terminal before running files it did not publish — once, until they change.
Each bundle's tests run without a funes binary, against fakes:

```sh
sh pi/test/run.sh
```

The `hf-traces` test needs pyarrow. `PYTHON` names the interpreter that has it:

```sh
PYTHON="uv run --with pyarrow python" sh hf-traces/test/run.sh
```

## Releasing

A release is an integration's directory packed as `<id>.tar.gz`, published under `<id>/<version>/`
in the `huggingface/funes-integrations` bucket with a `SHA256SUMS` beside it, and listed in the
bucket's `catalog.json`. Versions are the integration's own — `version` in its manifest,
`MAJOR.MINOR.PATCH` — independent of funes's, and a published version is never replaced.

1. Bump `version` in `<id>/manifest.json` and merge.
2. Tag `<id>-v<version>` — `pi-v1.0.1` — and push the tag, or run the Release workflow by hand
   with the id and version.

The workflow checks the manifest against the tag, runs the bundle's tests, packs and publishes the
archive, and adds the release to the catalog. It needs `HF_FUNES_INTEGRATIONS_RELEASE_TOKEN`: a token
that can write that bucket, and nothing else. Releases run one at a time, since the catalog is
read, amended and written back.

### The catalog

`catalog.json`, `catalog_version` 1:

```json
{
  "catalog_version": 1,
  "integrations": {
    "pi": {
      "repo": "huggingface/funes-integrations",
      "releases": [
        {
          "version": "1.0.0",
          "contract_version": 1,
          "url": "hf://buckets/huggingface/funes-integrations/pi/1.0.0/pi.tar.gz",
          "sha256": "…"
        }
      ]
    }
  }
}
```

For the id it was asked for, funes takes the newest release whose `contract_version` is the one it
speaks, fetches the archive at `url` with the `SHA256SUMS` beside it, and refuses it unless its
digest is `sha256` and its manifest declares `version`. Fields funes does not know are ignored.
