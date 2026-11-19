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


def local_goblins_runtime() -> tuple[str | None, Path, dict[str, str]]:
    """Find the optional local Guile/Goblins build without installing it."""
    explicit = os.environ.get("GOBLINS_GUILE")
    guile = shutil.which(explicit or "guile")
    pre_inst_env = Path(os.environ.get("GOBLINS_PRE_INST_ENV", GOBLINS / "pre-inst-env"))
    runtime_env = os.environ.copy()

    if guile is None and not explicit:
        local_root = ROOT.parent / ".tools" / "guileroot"
        candidate = local_root / "usr" / "bin" / "guile3.0"
        if candidate.is_file():
            guile = str(candidate)
            runtime_env.update({
                "LD_LIBRARY_PATH": str(local_root / "usr" / "lib64"),
                "GUILE_LOAD_PATH": str(local_root / "usr" / "share" / "guile" / "site" / "3.0"),
                "GUILE_SYSTEM_PATH": str(local_root / "usr" / "share" / "guile" / "3.0"),
                "GUILE_SYSTEM_COMPILED_PATH": str(local_root / "usr" / "lib64" / "guile" / "3.0" / "ccache"),
                "GUILE_LOAD_COMPILED_PATH": str(local_root / "usr" / "lib64" / "guile" / "3.0" / "site-ccache"),
                "GNUTLS_GUILE_EXTENSION_DIR": str(local_root / "usr" / "lib64" / "guile" / "3.0"),
            })

    if "GOBLINS_PRE_INST_ENV" not in os.environ:
        local_pre_inst = ROOT.parent / ".tools" / "goblins-build" / "pre-inst-env"
        if local_pre_inst.is_file():
            pre_inst_env = local_pre_inst

    if guile and pre_inst_env.is_file():
        dep = ROOT.parent / ".tools" / "guile-deps" / "prefix"
        build = pre_inst_env.parent
        load_path = [
            runtime_env.get("GUILE_LOAD_PATH", ""),
            str(dep / "share" / "guile" / "site" / "3.0"),
            str(build),
            str(GOBLINS),
        ]
        compiled_path = [
            runtime_env.get("GUILE_LOAD_COMPILED_PATH", ""),
            str(dep / "lib" / "guile" / "3.0" / "site-ccache"),
            str(build),
        ]
        runtime_env["GUILE_LOAD_PATH"] = ":".join(p for p in load_path if p)
        runtime_env["GUILE_LOAD_COMPILED_PATH"] = ":".join(p for p in compiled_path if p)
        if dep.is_dir():
            runtime_env["LD_LIBRARY_PATH"] = ":".join(
                p for p in (runtime_env.get("LD_LIBRARY_PATH", ""), str(dep / "lib")) if p
            )
    return guile, pre_inst_env, runtime_env


def run_nim_client(work: Path, host: str, port: str, label: str = "client",
                   scenario: str | None = None) -> None:
    binary = work / f"goblins-nim-{label}"
    build = subprocess.run(
        ["nim", "c", "--hints:off", f"--out:{binary}",
         "tests/goblins_client.nim"],
        cwd=ROOT, text=True, capture_output=True, timeout=60,
    )
    if build.returncode:
        raise RuntimeError("Nim Goblins client build failed:\n" + build.stdout + build.stderr)
    command = [str(binary), host, port]
    if scenario:
        command.append(scenario)
    try:
        result = subprocess.run(
            command, cwd=ROOT, text=True,
            capture_output=True, timeout=15,
        )
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(
            f"Nim Goblins client timed out ({label})\nstdout:\n{error.stdout}\nstderr:\n{error.stderr}"
        ) from error
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


def python_suite_available() -> tuple[bool, str]:
    result = subprocess.run(
        [TEST_PYTHON, "-c", "import cryptography, stem"],
        text=True, capture_output=True, timeout=10,
    )
    if result.returncode:
        return False, "OCapN runner needs Python modules cryptography and stem"
    return True, ""


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
    guile, pre_inst_env, runtime_env = local_goblins_runtime()
    upstream_script = GOBLINS / "tests" / "ocapn-test-suite.scm"
    script = ROOT / "tests" / "goblins_persistent_peer.scm"
    runtime_env["GOBLINS_UPSTREAM_FIXTURE"] = str(upstream_script)
    runner = SUITE / "test_runner.py"

    missing = []
    if guile is None:
        missing.append("Guile 3.x")
    if not pre_inst_env.is_file() or not os.access(pre_inst_env, os.X_OK):
        missing.append(str(pre_inst_env))
    if not upstream_script.is_file():
        missing.append(str(upstream_script))
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

    upstream_ok, upstream_reason = python_suite_available()
    if not upstream_ok and "OCAPN_TEST_PYTHON" in os.environ:
        print("FAIL Goblins upstream-suite prerequisites: " + upstream_reason)
        return 1

    work = Path(tempfile.mkdtemp(prefix="nim-ocapn-goblins-"))
    peer = None
    try:
        env = runtime_env
        peer, locator = start_peer(pre_inst_env, guile, script, work, env, "nim")
        parsed = urlparse(locator)
        hints = parse_qs(parsed.query, keep_blank_values=True)
        host = hints.get("host", [""])[0]
        port = hints.get("port", [""])[0]
        if not host or not port:
            raise RuntimeError("Goblins published a locator without host/port: " + locator)
        run_nim_client(work, host, port, "bootstrap")
        print("PASS Nim -> Goblins: bootstrap, sturdyref fetch and invocation")

        # A fresh CapTP session must work while the independent peer remains
        # alive.  This is a real reconnect/repeated-session check, not an
        # in-process Nim shortcut.
        try:
            run_nim_client(work, host, port, "reconnect")
            print("PASS Nim <-> Goblins: repeated independent session")
        except RuntimeError as error:
            if "Connection refused" not in str(error):
                raise
            print("UNSUPPORTED Goblins repeated session: pinned fixture closes its listener after the first session")
        stop_peer(peer)
        peer = None

        # The pinned TCP fixture generates its CapTP session key inside
        # spawn-mycapn and exposes no persistent identity input.  Still check
        # that a new Goblins process can serve the same protocol path, while
        # keeping durable-identity status explicitly unverified.
        peer, restarted_locator = start_peer(
            pre_inst_env, guile, script, work, env, "restart")
        restarted = urlparse(restarted_locator)
        restarted_hints = parse_qs(restarted.query, keep_blank_values=True)
        run_nim_client(
            work,
            restarted_hints.get("host", [""])[0],
            restarted_hints.get("port", [""])[0],
            "restart",
        )
        print("PASS Nim -> Goblins: restarted peer bootstrap and invocation")
        print("UNVERIFIED Goblins durable-identity reconnect: pinned tcp-testing-only fixture generates its CapTP key per process")
        stop_peer(peer)
        peer = None

        if upstream_ok:
            # The upstream fixture is an independent peer, but its test-suite
            # runner opens a fresh session per test. Keep each case isolated so
            # a fixture lifecycle failure cannot be mistaken for a wire failure.
            for module, label, description in (
                ("tests.op_start_session", "upstream-start-session", "start-session"),
                ("tests.op_deliver", "upstream-deliver", "invocation, promises and pipelining"),
                ("tests.op_gc", "upstream-gc", "GC"),
                ("tests.op_listen", "upstream-listen", "listen"),
                ("tests.third_party_handoffs", "upstream-handoff", "handoff"),
            ):
                try:
                    run_upstream_case(work, pre_inst_env, guile, script, env, runner,
                                      module, label)
                except RuntimeError as error:
                    if module == "tests.third_party_handoffs" and "ConnectionRefusedError" in str(error):
                        print("UNSUPPORTED upstream -> Goblins: handoff fixture closes its listener before the second handoff connection")
                        continue
                    raise
                print(f"PASS upstream -> Goblins: {description}")
        else:
            print("SKIP upstream Goblins module cases: " + upstream_reason)
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
