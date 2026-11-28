"""The plugin's hooks, driven as hermes drives them: a turn converts the session that spoke and
spawns the index script; a session boundary spawns it in publish mode — both through `sh`, the one
shell a box running hermes is promised. Loads the plugin as installed, with a fake index script
that records what it was launched for.

    python3 integrations/hermes/test/hooks.py    (run.sh runs it)
"""

import importlib.util
import os
import shutil
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.join(HERE, "..", "plugin")


def fail(why):
    sys.exit(f"hermes hooks: {why}")


tmp = tempfile.mkdtemp(prefix="funes-hermes-hooks-")
# Only `sh` is promised on a box running hermes: a `bash` that fails proves nothing is spawned
# through it.
shims = os.path.join(tmp, "shims")
os.makedirs(shims)
# Scripts are written with `\n`, which `sh` reads: Windows would end each line with CRLF.
with open(os.path.join(shims, "bash"), "w", encoding="utf-8", newline="\n") as f:
    f.write("#!/bin/sh\nexit 127\n")
os.chmod(os.path.join(shims, "bash"), 0o755)
os.environ["PATH"] = shims + os.pathsep + os.environ.get("PATH", "")

# The plugin as installed: its files, the records `setup add` writes beside them, and an index
# script that records what it was launched for.
dest = os.path.join(tmp, "funes")
shutil.copytree(PLUGIN, dest, ignore=shutil.ignore_patterns("test", "__pycache__"))
spool = os.path.join(tmp, "spool")
os.makedirs(spool)
db = os.path.join(tmp, "state.db")
shutil.copy(os.path.join(PLUGIN, "test", "state.db"), db)
for name, value in (("spool", spool), ("state-db", db), ("memory", "acme/kb")):
    with open(os.path.join(dest, name), "w", encoding="utf-8") as f:
        f.write(value + "\n")
log = os.path.join(tmp, "worker.log")
script = os.path.join(dest, "funes-index.sh")
with open(script, "w", encoding="utf-8", newline="\n") as f:
    f.write(f"#!/bin/sh\nprintf '%s: %s\\n' \"${{HF_HUB_USER_AGENT_ORIGIN:-}}\" \"$*\" >>\"{log}\"\n")
os.chmod(script, 0o755)

# The hermes the plugin runs inside, for the version funes names.
fake_hermes = os.path.join(tmp, "site")
os.makedirs(os.path.join(fake_hermes, "hermes_cli"))
with open(os.path.join(fake_hermes, "hermes_cli", "__init__.py"), "w", encoding="utf-8") as f:
    f.write('__version__ = "9.9.9"\n')
sys.path.insert(0, fake_hermes)
os.environ.pop("HF_HUB_USER_AGENT_ORIGIN", None)

# Loaded as the package hermes loads.
spec = importlib.util.spec_from_file_location("funes", os.path.join(dest, "__init__.py"), submodule_search_locations=[dest])
plugin = importlib.util.module_from_spec(spec)
sys.modules["funes"] = plugin
spec.loader.exec_module(plugin)

hooks = {}


class Ctx:
    def register_hook(self, event, fn):
        hooks.setdefault(event, []).append(fn)


plugin.register(Ctx())
if set(hooks) != {"post_llm_call", "on_session_start", "on_session_finalize"}:
    fail(f"registered {sorted(hooks)}")

# A turn of the fixture's session: converted into the spool, then the index spawned.
for fn in hooks["post_llm_call"]:
    fn(session_id="20260101_000000_fixture")
if not os.path.isfile(os.path.join(spool, "20260101_000000_fixture.funes.jsonl")):
    fail("the turn was not converted")
# A boundary: the publish.
for fn in hooks["on_session_finalize"]:
    fn()

# Two detached launches, which nothing orders: both are recorded, in whichever order they ran.
deadline = time.time() + 10
origin = "funes; agent/hermes; agent_version/9.9.9"
expected = f"{origin}: \n{origin}: --publish\n"
while True:
    try:
        with open(log, encoding="utf-8") as f:
            got = f.read()
    except OSError:
        got = ""
    if got.endswith("\n") and sorted(got.splitlines()) == sorted(expected.splitlines()):
        break
    if time.time() > deadline:
        fail(f"the index script was launched with {got!r}, expected {expected!r}")
    time.sleep(0.05)

# On Windows the shell comes from a directory PATH names in full, or from Git's install, never from
# the project hermes runs in, which Windows searches first: not a shell planted there, nor one in a
# directory PATH names relative to it. With no shell anywhere, there is none to start.
if os.name == "nt":
    project = os.path.join(tmp, "project")
    os.makedirs(os.path.join(project, "bin"))
    for planted in ("sh.bat", "sh.cmd", "sh.exe", os.path.join("bin", "sh.exe")):
        with open(os.path.join(project, planted), "w", encoding="utf-8") as f:
            f.write("@echo off\n")
    saved_env, saved_cwd = dict(os.environ), os.getcwd()
    os.chdir(project)
    try:
        # As Windows has it by default: a lookup by bare name searches the current directory first.
        os.environ.pop("NoDefaultCurrentDirectoryInExePath", None)
        for path in (saved_env["PATH"], "bin" + os.pathsep + saved_env["PATH"]):
            os.environ["PATH"] = path
            sh = plugin._sh()
            if not sh or os.path.abspath(sh).lower().startswith(project.lower()):
                fail(f"the shell was taken from the project: {sh!r}")
        empty = os.path.join(tmp, "empty")
        os.makedirs(empty)
        for name in ("PATH", "ProgramFiles", "ProgramW6432", "LOCALAPPDATA"):
            os.environ[name] = empty
        if plugin._sh() is not None:
            fail(f"with no shell anywhere, took {plugin._sh()!r}")
    finally:
        os.chdir(saved_cwd)
        os.environ.clear()
        os.environ.update(saved_env)

# A shell that cannot be started costs the run, never an exception in hermes, at a turn or at
# either boundary.
plugin._sh = lambda: os.path.join(tmp, "no-such-shell", "sh")
try:
    for event in ("post_llm_call", "on_session_start", "on_session_finalize"):
        for fn in hooks[event]:
            fn(session_id="20260101_000000_fixture")
except OSError as e:
    fail(f"a hook raised into hermes: {e!r}")
shutil.rmtree(tmp)
print("hermes hooks: ok")
