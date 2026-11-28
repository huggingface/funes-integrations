"""funes automation for hermes: the lifecycle hooks that keep the memory current.

Each completed turn is converted out of hermes's SQLite store into the turns file funes indexes, in
this process — it is a read and an atomic write — and the index is spawned detached and forgotten,
as is the publish at a session boundary, so nothing here waits on an embedder or a network. The
publish takes its memory from the `memory` file beside this plugin, which `setup add` writes with
the memory it was handed. With none, the file is absent, and the publish hooks are not registered.
"""

import os
import subprocess
import time

from . import convert

HERE = os.path.dirname(os.path.abspath(__file__))


def _hub_origin():
    """funes, hermes and the running hermes's version, as funes's Hub requests name them: hf-hub
    appends HF_HUB_USER_AGENT_ORIGIN to its User-Agent. An origin already set is kept in front."""
    parts = [os.environ.get("HF_HUB_USER_AGENT_ORIGIN"), "funes; agent/hermes"]
    try:
        from hermes_cli import __version__

        parts.append(f"agent_version/{__version__}")
    except ImportError:
        pass
    return "; ".join(p for p in parts if p)


def _beside(name):
    """A path `funes add hermes` recorded beside this plugin, or None when it did not."""
    try:
        with open(os.path.join(HERE, name), encoding="utf-8") as f:
            return f.read().strip() or None
    except OSError:
        return None


def _convert(session_id):
    """The session that just spoke, as a turns file in the spool; returns its id. hermes names it
    when its hook carries one; otherwise it is the session whose message landed last, which is the
    same session. A hook must never raise into hermes, so a store this cannot read costs the turn's
    capture and nothing else."""
    spool, db = _beside("spool"), _beside("state-db")
    if not spool or not db:
        return None
    try:
        session_id = session_id or convert.latest_session_id(db)
        convert.convert(db, spool, session_id)
        return session_id
    except Exception:
        return None


def _convert_stale(named):
    """The sessions that spoke since the last sweep: those whose own hook never ran, a hermes that
    died mid-turn among them. What the spool holds cannot say which those are (funes drains it), so
    the sweep keeps its own mark: the previous sweep's stamp, or, before there is one, the `spool`
    record `funes add hermes` wrote just before it converted the history. The session that just
    spoke was converted already and is skipped."""
    spool, db = _beside("spool"), _beside("state-db")
    if not spool or not db:
        return
    mark = os.path.join(HERE, "swept")
    try:
        since = os.path.getmtime(mark if os.path.exists(mark) else os.path.join(HERE, "spool"))
        # Stamped before the sweep, so a session that speaks while it runs is swept again next turn.
        now = time.time()
        for session_id in convert.session_ids_since(db, since):
            if session_id == named:
                continue
            # One session that cannot be converted costs its own capture, not the sweep's.
            try:
                convert.convert(db, spool, session_id)
            except Exception:
                pass
        with open(mark, "a", encoding="utf-8"):
            pass
        os.utime(mark, (now, now))
    except Exception:
        pass


def _sh():
    """The `sh` to run the scripts with: the one shell a box running hermes is promised, except on
    Windows, which has none of its own. There it is the first `sh.exe` in a directory PATH names,
    else Git for Windows' — beside the `git.exe` in one, or where its installer puts it — and None
    when there is none. Only directories named in full are searched: the current one, which Windows
    searches first, is the project hermes runs in, and a `sh.bat` there is no shell to run."""
    if os.name != "nt":
        return "sh"
    dirs = [os.path.normpath(d) for d in os.environ.get("PATH", "").split(os.pathsep) if os.path.isabs(d)]
    candidates = [os.path.join(d, "sh.exe") for d in dirs]
    candidates += [
        os.path.join(os.path.dirname(d), "bin", "sh.exe") for d in dirs if os.path.isfile(os.path.join(d, "git.exe"))
    ]
    for base in ("ProgramFiles", "ProgramW6432", "LOCALAPPDATA"):
        root = os.environ.get(base)
        if root and os.path.isabs(root):
            candidates += [os.path.join(root, "Git", "bin", "sh.exe"), os.path.join(root, "Programs", "Git", "bin", "sh.exe")]
    return next((c for c in candidates if os.path.isfile(c)), None)


def _spawn(script, *args):
    """Run `script` detached and forget it, through `sh`. On Windows the script is named with `/`,
    which a shell does not take for an escape, and the worker gets no console window to show. A
    hook must never raise into hermes, so a shell that cannot be started, or none to start, costs
    the run and nothing else."""
    sh = _sh()
    if not sh:
        return
    env = dict(os.environ, HF_HUB_USER_AGENT_ORIGIN=_hub_origin())
    path = os.path.join(HERE, script)
    detach = {"start_new_session": True}
    if os.name == "nt":
        path = path.replace("\\", "/")
        detach = {"creationflags": subprocess.CREATE_NO_WINDOW | subprocess.CREATE_NEW_PROCESS_GROUP}
    try:
        subprocess.Popen(
            [sh, path, *args],
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            **detach,
        )
    except OSError:
        pass


def _on_turn(**kwargs):
    _convert_stale(_convert(kwargs.get("session_id")))
    _spawn("funes-index.sh")


def register(ctx):
    ctx.register_hook("post_llm_call", _on_turn)
    if os.path.exists(os.path.join(HERE, "memory")):
        # `on_session_start` catches up whatever a session that never finalized left unpublished.
        for event in ("on_session_start", "on_session_finalize"):
            ctx.register_hook(event, lambda **kwargs: _spawn("funes-index.sh", "--publish"))
