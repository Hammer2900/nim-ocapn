#!/usr/bin/env python3
"""Bounded advanced interop cases using unmodified external peers."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from test_interop import GLOWCAP, locator_port, read_until, start_glowcap_listener


ROOT = Path(__file__).resolve().parents[1]
TIMEOUT = 30


def report(scenario: str, status: str, detail: str) -> None:
    print(f"{status} {scenario}: {detail}")


def stop_process(process: subprocess.Popen[str] | None) -> None:
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=3)


def build_nim_client(work: Path) -> Path:
    binary = work / "native_glowcap_client"
    result = subprocess.run(
        ["nim", "c", "--hints:off", f"--out:{binary}",
         "examples/native_glowcap_client.nim"],
        cwd=ROOT, text=True, capture_output=True, timeout=TIMEOUT,
    )
    if result.returncode:
        raise RuntimeError("Nim interop client build failed:\n" + result.stdout + result.stderr)
    return binary


def start_existing_glowcap(state: Path):
    env = os.environ.copy()
    env["GLOWCAP_STATE"] = str(state)
    process = subprocess.Popen(
        [str(GLOWCAP), "--json", "ocapn", "listen", "--publish", "greeter"],
        cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    output = read_until(process, "locator", 10)
    return process, locator_port(output)


def run_repeated_glowcap(work: Path) -> None:
    if not GLOWCAP.is_file() or not os.access(GLOWCAP, os.X_OK):
        report("reconnect/repeated-session", "SKIP", f"Glowcap binary not found: {GLOWCAP}")
        return

    client = build_nim_client(work)
    state = work / "persistent-glowcap-state"
    for cycle in range(1, 3):
        peer = None
        try:
            if cycle == 1:
                peer, port = start_glowcap_listener(state)
            else:
                peer, port = start_existing_glowcap(state)
            result = subprocess.run(
                [str(client), "127.0.0.1", str(port)], cwd=ROOT,
                text=True, capture_output=True, timeout=TIMEOUT,
            )
            if result.returncode or result.stdout.strip() != "Hello, world":
                raise RuntimeError(
                    f"cycle {cycle} failed ({result.returncode}):\n"
                    f"{result.stdout}\n{result.stderr}"
                )
            report("reconnect/repeated-session", "PASS", f"cycle {cycle}; persistent peer state")
        finally:
            stop_process(peer)


def main() -> int:
    work = Path(tempfile.mkdtemp(prefix="nim-ocapn-advanced-interop-"))
    try:
        run_repeated_glowcap(work)
        report("op:listen mode 1", "UNVERIFIED",
               "Glowcap CLI does not expose a selectable listen-mode driver")
        report("op:listen mode 2", "UNVERIFIED",
               "Glowcap CLI does not expose a selectable listen-mode driver")
        report("op:listen mode 3", "UNVERIFIED",
               "Glowcap CLI does not expose a selectable listen-mode driver")
        report("Glowcap promise pipelining", "UNSUPPORTED",
               "Glowcap CLI exposes no bounded pipeline fixture; pinned Goblins keeps pipeline tests inside its Guile vat tests")
        report("cross-peer handoff", "UNSUPPORTED",
               "Glowcap CLI has no handoff fixture; pinned Goblins exposes handoff through Guile internals, not an external driver")
        report("wire-level distributed GC", "UNSUPPORTED",
               "independent peers expose no resource-observation fixture")
        return 0
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        report("advanced interoperability", "FAIL", str(error))
        print(f"diagnostics preserved: {work}")
        return 1
    finally:
        if os.environ.get("KEEP_INTEROP_LOGS") != "1":
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
