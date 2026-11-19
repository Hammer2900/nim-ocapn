#!/usr/bin/env python3
"""Run the upstream OCapN suite against an unmodified Guile Goblins peer."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import parse_qs, urlparse


ROOT = Path(__file__).resolve().parents[1]
GOBLINS = Path(os.environ.get("GOBLINS_DIR", ROOT.parent / "goblins"))
SUITE = Path(os.environ.get("OCAPN_TEST_SUITE", ROOT.parent / "ocapn-test-suite"))
START_TIMEOUT = 20.0
SUITE_TIMEOUT = 180.0
TEST_PYTHON = os.environ.get("OCAPN_TEST_PYTHON", sys.executable)


def run_nim_client(work: Path, host: str, port: str) -> None:
    binary = work / "goblins-nim-client"
    build = subprocess.run(
        ["nim", "c", "--hints:off", f"--out:{binary}",
         "tests/goblins_client.nim"],
        cwd=ROOT, text=True, capture_output=True, timeout=60,
    )
    if build.returncode:
        raise RuntimeError("Nim Goblins client build failed:\n" + build.stdout + build.stderr)
    result = subprocess.run(
        [str(binary), host, port], cwd=ROOT, text=True,
        capture_output=True, timeout=30,
    )
    if result.returncode or "nim-to-goblins" not in result.stdout:
        raise RuntimeError(
            "Nim -> Goblins invocation failed\nstdout:\n"
            + result.stdout + "\nstderr:\n" + result.stderr
        )


def start_peer(pre_inst_env: Path, guile: str, script: Path, work: Path,
               env: dict[str, str], label: str):
    locator_file = work / f"{label}.locator"
    peer = subprocess.Popen(
        ["sh", str(pre_inst_env), guile, str(script), "tcp-testing-only"],
        cwd=GOBLINS,
        env={**env, "GOBLINS_OCAPN_PEER_LOCATOR": str(locator_file)},
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    deadline = time.monotonic() + START_TIMEOUT
    locator = ""
    while time.monotonic() < deadline and not locator:
        if peer.poll() is not None:
            break
        if locator_file.exists():
            locator = locator_file.read_text(encoding="utf-8").strip()
            if locator:
                break
        time.sleep(0.05)
    if not locator:
        stop_peer(peer)
        output = ""
        if peer.stdout:
            try:
                output, _ = peer.communicate(timeout=1)
            except subprocess.TimeoutExpired:
                output = "<Goblins output unavailable after termination>"
        raise RuntimeError(f"Goblins readiness failed ({label}):\n{output}")
    return peer, locator


def stop_peer(peer) -> None:
    if peer is not None and peer.poll() is None:
        peer.terminate()
        try:
            peer.wait(timeout=3)
        except subprocess.TimeoutExpired:
            peer.kill()
            peer.wait()


def run_upstream_case(work: Path, pre_inst_env: Path, guile: str,
                      script: Path, env: dict[str, str], runner: Path,
                      module: str, label: str) -> None:
    peer, locator = start_peer(pre_inst_env, guile, script, work, env, label)
    try:
        result = subprocess.run(
            [TEST_PYTHON, str(runner), "--captp-version=1.0",
             "--test-module", module, locator],
            cwd=SUITE,
            env=os.environ.copy(),
            text=True,
            capture_output=True,
            timeout=SUITE_TIMEOUT,
        )
        if result.returncode:
            raise RuntimeError(
                f"upstream case failed ({label}: {module})\nstdout:\n"
                + result.stdout + "\nstderr:\n" + result.stderr
            )
    finally:
        stop_peer(peer)


def main() -> int:
    explicitly_configured = "GOBLINS_PRE_INST_ENV" in os.environ
    pre_inst_env = Path(os.environ.get("GOBLINS_PRE_INST_ENV", GOBLINS / "pre-inst-env"))
    guile_name = os.environ.get("GOBLINS_GUILE", "guile")
    guile = shutil.which(guile_name)
    script = GOBLINS / "tests" / "ocapn-test-suite.scm"
    runner = SUITE / "test_runner.py"

    missing = []
    if guile is None:
        missing.append("Guile 3.x")
    if not pre_inst_env.is_file() or not os.access(pre_inst_env, os.X_OK):
        missing.append(str(pre_inst_env))
    if not script.is_file():
        missing.append(str(script))
    if not runner.is_file():
        missing.append(str(runner))
    if missing and not explicitly_configured:
        print("SKIP Goblins bootstrap/sturdyref interop: missing " + ", ".join(missing))
        return 0
    if missing:
        print("FAIL Goblins interop prerequisites: " + ", ".join(missing))
        return 1

    work = Path(tempfile.mkdtemp(prefix="nim-ocapn-goblins-"))
    peer = None
    try:
        env = os.environ.copy()
        peer, locator = start_peer(pre_inst_env, guile, script, work, env, "nim")
        parsed = urlparse(locator)
        hints = parse_qs(parsed.query, keep_blank_values=True)
        host = hints.get("host", [""])[0]
        port = hints.get("port", [""])[0]
        if not host or not port:
            raise RuntimeError("Goblins published a locator without host/port: " + locator)
        run_nim_client(work, host, port)
        print("PASS Nim -> Goblins: bootstrap, sturdyref fetch and invocation")
        stop_peer(peer)
        peer = None

        # The upstream fixture is an independent peer, but its test-suite
        # runner opens a fresh session per test. Keep each case isolated so a
        # fixture lifecycle failure cannot be mistaken for a wire failure in
        # the case being measured.
        for module, label, description in (
            ("tests.op_start_session", "upstream-start-session", "start-session"),
            ("tests.op_deliver", "upstream-deliver", "invocation, promises and pipelining"),
            ("tests.op_gc", "upstream-gc", "GC"),
            ("tests.op_listen", "upstream-listen", "listen"),
            ("tests.third_party_handoffs", "upstream-handoff", "handoff"),
        ):
            run_upstream_case(work, pre_inst_env, guile, script, env, runner,
                              module, label)
            print(f"PASS upstream -> Goblins: {description}")
        print("UNSUPPORTED Goblins full upstream suite: fixture does not keep its listener available for the suite's repeated sessions")
        return 0
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print("FAIL Goblins bootstrap/sturdyref interop", file=sys.stderr)
        print(error, file=sys.stderr)
        print(f"diagnostics: {work}", file=sys.stderr)
        return 1
    finally:
        stop_peer(peer)
        if os.environ.get("KEEP_INTEROP_LOGS") != "1":
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
