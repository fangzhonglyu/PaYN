"""Shared plumbing of the PaYN flow entry points (route.py, measure.py, report.py, regress.py's gate-level mode).

  tool_env()       the environment of flow/env.sh (module versions, ASTRAEA_FLOW, the qualified APR/GL block),
                   captured once and passed to every tool command
  sh / make        run a command (or `make <target>` in the repo against ASTRAEA) with its output in a log
  qualify          run a flow/qualify.py gate
  Stage / Runner   resumable stages: an explicit PASS marker per stage, one log per attempt, failed outputs moved
                   aside only on --retry-failed, a printed plan on --dry-run
  netlist helpers  the guide line and the port count a route of a netlist must reproduce
"""
from __future__ import annotations

import datetime
import fcntl
import os
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

REPO = Path(__file__).resolve().parent.parent
FLOW = REPO / "flow"
QUALIFY = FLOW / "qualify.py"
MODEL = REPO / "designs/payn/model"
TARGET = "TSMC22/PAYN"
TOP = "payn_array"
PERIOD_NS = 2.5
SHAPES = {"k16m8": (16, 8), "k8m16": (8, 16)}        # shape -> (K lanes, M positions)


class FlowError(RuntimeError):
    """A stage's check failed; the message names it."""


def require(condition, message: str) -> None:
    if not condition:
        raise FlowError(message)


def payn_m(shape: str) -> int:
    return SHAPES[shape][1]


def apr_dir(target: str = TARGET) -> Path:
    return REPO / "apr/build" / target


def syn_dir(target: str = TARGET) -> Path:
    return REPO / "syn/build" / target


# --------------------------------------------------------------------------------------------- environment --
_ENV: dict[str, str] | None = None


def tool_env(extra: dict | None = None) -> dict[str, str]:
    """flow/env.sh's environment (sourced once per process), updated by extra (a None value unsets)."""
    global _ENV
    if _ENV is None:
        cmd = f"source {shlex.quote(str(FLOW / 'env.sh'))} >/dev/null 2>&1 && env -0"
        out = subprocess.run(["bash", "-c", cmd], capture_output=True, check=True).stdout.decode()
        _ENV = dict(kv.split("=", 1) for kv in out.split("\0") if "=" in kv)
    env = dict(_ENV)
    for key, value in (extra or {}).items():
        if value is None:
            env.pop(key, None)
        else:
            env[key] = str(value)
    return env


def astraea() -> str:
    return tool_env()["ASTRAEA_FLOW"]


# -------------------------------------------------------------------------------------------------- logging --
class Log:
    """A stage log: messages and tool output in one file; messages also go to stdout when echo is set."""

    def __init__(self, path: Path, echo: bool = False):
        self.path = path
        path.parent.mkdir(parents=True, exist_ok=True)
        self.stream = open(path, "a", buffering=1)
        self.echo = echo

    def __call__(self, message: str) -> None:
        self.stream.write(message + "\n")
        if self.echo:
            print(message, flush=True)

    def close(self) -> None:
        self.stream.close()


def quote(cmd) -> str:
    return cmd if isinstance(cmd, str) else " ".join(shlex.quote(str(c)) for c in cmd)


def sh(cmd, log: Path | Log, cwd: Path = REPO, env: dict | None = None, append: bool = False) -> int:
    """Run cmd (list, or a string for bash) with stdout+stderr to log; return the exit code."""
    env = env if env is not None else tool_env()
    if isinstance(log, Log):
        log(f"$ {quote(cmd)}")
        stream, close = log.stream, False
    else:
        log.parent.mkdir(parents=True, exist_ok=True)
        stream, close = open(log, "a" if append else "w"), True
    try:
        args = ["bash", "-c", cmd] if isinstance(cmd, str) else [str(c) for c in cmd]
        return subprocess.run(args, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT).returncode
    finally:
        if close:
            stream.close()


def make_cmd(target: str, *args: str) -> list[str]:
    return ["make", "--no-print-directory", target, *args, "NTFY_CHNL=", f"ASTRAEA_FLOW={astraea()}"]


def make(target: str, args: list[str], log: Path | Log, env_extra: dict | None = None) -> int:
    return sh(make_cmd(target, *args), log, env=tool_env(env_extra))


def qualify_cmd(*args) -> list[str]:
    return [sys.executable, str(QUALIFY), *[str(a) for a in args]]


def qualify(*args, log: Path | Log) -> int:
    return sh(qualify_cmd(*args), log)


def model_cmd(tool: str, *args) -> list[str]:
    return [sys.executable, str(MODEL / tool), *[str(a) for a in args]]


def text(path: Path) -> str:
    return path.read_text(errors="replace") if path.is_file() else ""


def grep(path: Path, pattern: str, fixed: bool = True) -> bool:
    body = text(path)
    return pattern in body if fixed else re.search(pattern, body, re.M) is not None


def first_match(path: Path, pattern: str) -> re.Match | None:
    return re.search(pattern, text(path), re.M)


def now() -> str:
    return datetime.datetime.now().isoformat(timespec="seconds")


def stamp() -> str:
    return datetime.datetime.now().strftime("%Y%m%d_%H%M%S")


# --------------------------------------------------------------------------------------------------- stages --
@dataclass
class Stage:
    """One resumable step.  action(log) does the work and raises on failure; describe() returns the plan lines
    printed by --dry-run.  adopt(log), if given, qualifies an artifact that exists before the first attempt (a run
    launched outside the flow with the same environment) instead of redoing it, when the runner allows adoption."""
    name: str
    artifact: Path
    action: Callable[[Log], None]
    describe: Callable[[], list[str]]
    needs: tuple[str, ...] = ()
    adopt: Callable[[Log], None] | None = None


@dataclass
class Runner:
    work: Path
    retry: bool = False
    dry: bool = False
    allow_adopt: bool = False
    label: str = ""
    done: list[str] = field(default_factory=list)

    def marker(self, name: str) -> Path:
        return self.work / f"{name}.status"

    def passed(self, name: str) -> bool:
        return text(self.marker(name)).strip() == "PASS"

    def state(self, st: Stage) -> str:
        if self.passed(st.name):
            return "PASS" if st.artifact.exists() else "PASS marker without its artifact"
        attempts = sorted(self.work.glob(f"{st.name}.attempt_*.log"))
        if attempts:
            return f"unfinished ({len(attempts)} attempt(s); --retry-failed reruns it)"
        if st.artifact.exists():
            return "artifact exists without a marker" + (" (adoptable)" if st.adopt else "")
        return "pending"

    def run(self, stages: list[Stage], only: set[str] | None = None) -> None:
        names = [s.name for s in stages]
        for name in only or ():
            require(name in names, f"unknown stage {name} (stages: {', '.join(names)})")
        for st in stages:
            if only and st.name not in only:
                continue
            if self.dry:
                self.plan(st)
                continue
            for dep in st.needs:
                require(self.passed(dep), f"{st.name} needs stage {dep} to have passed ({self.marker(dep)})")
            self.one(st)

    def plan(self, st: Stage) -> None:
        print(f"{self.label}stage {st.name}: {self.state(st)}")
        print(f"    output   {st.artifact}")
        if st.needs:
            print(f"    needs    {', '.join(st.needs)}")
        for line in st.describe():
            print(f"    {line}")

    def one(self, st: Stage) -> None:
        self.work.mkdir(parents=True, exist_ok=True)
        marker = self.marker(st.name)
        if marker.exists():
            require(self.passed(st.name) and st.artifact.exists(), f"invalid completed stage {st.name} ({marker})")
            print(f"{self.label}reuse completed {st.name}", flush=True)
            self.done.append(st.name)
            return
        lock = open(self.work / f"{st.name}.lock", "w")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise FlowError(f"another worker owns stage {st.name} ({self.work})")
        attempt = 1
        while (self.work / f"{st.name}.attempt_{attempt}.log").exists():
            attempt += 1
        adopting = attempt == 1 and st.artifact.exists() and st.adopt is not None and self.allow_adopt
        if (st.artifact.exists() or attempt > 1) and not adopting:
            require(self.retry, f"unfinished {st.name} preserved ({st.artifact}); inspect its logs, then rerun with "
                                f"--retry-failed")
            if st.artifact.exists():
                aside = st.artifact.with_name(f"{st.artifact.name}.failed_{stamp()}_{os.getpid()}")
                st.artifact.rename(aside)
                print(f"{self.label}{st.name}: moved the unfinished output aside to {aside}", flush=True)
        log = Log(self.work / f"{st.name}.attempt_{attempt}.log")
        print(f"{self.label}{st.name} {'adoption' if adopting else 'started'} {now()}; {log.path}", flush=True)
        try:
            (st.adopt if adopting else st.action)(log)
        except Exception as error:
            log(f"FAILED: {error}")
            with open(self.work / "failures.log", "a") as failures:
                failures.write(f"FAILED stage={st.name} attempt={attempt} time={now()}: {error}\n")
            raise FlowError(f"{st.name} failed: {error} (log {log.path})") from error
        finally:
            log.close()
            lock.close()
        marker.write_text("PASS\n")
        self.done.append(st.name)
        print(f"{self.label}{st.name} passed {now()}", flush=True)


def write_manifest(path: Path, lines: list[str]) -> None:
    """Record the inputs of a run directory once; a rerun with different inputs is refused."""
    body = "\n".join(lines) + "\n"
    if path.exists():
        require(path.read_text() == body, f"inputs changed since {path} was written; use a new run name")
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body)


def sha256(path: Path) -> str:
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


# ------------------------------------------------------------------------------------------------- netlists --
def netlist_modules(netlist: Path) -> dict[str, str]:
    body = netlist.read_text()
    starts = [(m.start(), m[1]) for m in re.finditer(r"^\s*module\s+(\S+)\s*\(", body, re.M)]
    return {name: body[pos:body.index("endmodule", pos)] for pos, name in starts}


def _child(mods: dict[str, str], body: str, inst: str) -> str:
    for m in re.finditer(r"^\s*(\S+)\s+(\\\S+|\S+)\s*\(\s*\.", body, re.M):
        if m[2] == inst:
            return mods[m[1]]
    raise FlowError(f"instance {inst} not found in the netlist")


def expected_guide_line(netlist: Path, nh: int = 8, nw: int = 8) -> str:
    """The SC_DISTRIBUTION_GUIDES line apr/scripts/sc_distribution_guides.tcl prints for this netlist (its globs,
    counted on the netlist's u_pe/u_array_core instances)."""
    mods = netlist_modules(netlist)
    top = next(body for body in mods.values() if re.search(r"^\s*\S+\s+u_pe\s*\(", body, re.M))
    core = _child(mods, _child(mods, top, "u_pe"), "u_array_core")
    insts = [m[2].lstrip("\\") for m in re.finditer(r"^\s*(\S+)\s+(\\\S+|\S+)\s*\(\s*\.", core, re.M)]

    def count(stems, i):
        return sum(1 for c in insts if any(c.startswith(f"{s}_reg_{i}__") for s in stems))
    a = sum(count(("a_bits_pipe", "a_signs_pipe"), h) for h in range(nh))
    w = sum(count(("w_bits_pipe", "w_encoded_pipe", "w_signs_pipe"), v) for v in range(nw))
    keep = sum(count(("w_keep_pipe",), v) for v in range(nw))
    require(all(count(("a_bits_pipe",), h) for h in range(nh)) and all(count(("w_bits_pipe",), v) for v in range(nw)),
            f"{netlist}: a row or column without bit-pipe flops")
    return f"SC_DISTRIBUTION_GUIDES: nh={nh} nw={nw} band=0.55 density=0.72 a_cells={a} w_cells={w} w_keep={keep}"


def port_count(netlist: Path, top: str) -> int:
    """Number of top-level port bits (the pins the pre-place script fixes)."""
    body = netlist_modules(netlist)[top]
    n = 0
    for d in re.finditer(r"^\s*(input|output|inout)\s*(\[(\d+):(\d+)\])?\s*([^;]+);", body, re.M):
        width = abs(int(d[3]) - int(d[4])) + 1 if d[2] else 1
        n += width * len([x for x in d[5].split(",") if x.strip()])
    return n
