#!/usr/bin/env python3
"""Run the smallest reproducible two-way test against an unmodified Glowcap."""

from __future__ import annotations

import json
import os
import re
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GLOWCAP = Path(os.environ.get("GLOWCAP_BIN", ROOT.parent / "glowcap" / "zig-out" / "bin" / "glowcap"))


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def read_until(proc: subprocess.Popen[str], needle: str, timeout: float) -> str:
    deadline = time.monotonic() + timeout
    lines: list[str] = []
    while time.monotonic() < deadline:
        if not proc.stdout:
            break
        ready, _, _ = select.select([proc.stdout], [], [],
                                    max(0.0, deadline - time.monotonic()))
        if not ready:
            break
        line = proc.stdout.readline()
        if line:
            lines.append(line)
            if needle in line:
                return "".join(lines)
        elif proc.poll() is not None:
            break
    tail = ""
    if proc.stdout and proc.poll() is not None:
        tail = proc.stdout.read()
    raise RuntimeError("readiness failed: " + "".join(lines) + tail)


def run_checked(command: list[str], *, env: dict[str, str], timeout: float) -> str:
    result = subprocess.run(command, cwd=ROOT, env=env, text=True,
                            capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(
            f"command failed ({result.returncode}): {' '.join(command)}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}")
    return result.stdout


def locator_port(output: str) -> int:
    match = re.search(r"127\.0\.0\.1%3A(\d+)\.tcp", output)
    if not match:
        raise RuntimeError("Glowcap did not publish a loopback tcp locator: " + output)
    return int(match.group(1))


def start_glowcap_listener(state: Path) -> tuple[subprocess.Popen[str], int]:
    env = os.environ.copy()
    env["GLOWCAP_STATE"] = str(state)
    run_checked([str(GLOWCAP), "--json", "init"], env=env, timeout=10)
    proc = subprocess.Popen(
        [str(GLOWCAP), "--json", "ocapn", "listen", "--publish", "greeter"],
        cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    output = read_until(proc, "locator", 10)
    return proc, locator_port(output)


def write_log(directory: Path, name: str, content: str) -> None:
    (directory / name).write_text(content, encoding="utf-8")


def main() -> int:
    if not GLOWCAP.is_file() or not os.access(GLOWCAP, os.X_OK):
        print(f"SKIP: Glowcap binary not found: {GLOWCAP}")
        return 0

    work = Path(tempfile.mkdtemp(prefix="nim-ocapn-interop-"))
    failures: list[str] = []
    try:
        client_binary = work / "native_glowcap_client"
        build = subprocess.run(
            ["nim", "c", "--hints:off", f"--out:{client_binary}",
             "examples/native_glowcap_client.nim"],
            cwd=ROOT, text=True, capture_output=True, timeout=30,
        )
        if build.returncode:
            write_log(work, "nim-client-build.log", build.stdout + build.stderr)
            raise RuntimeError("failed to build Nim Glowcap client")

        # Nim -> unmodified Glowcap over the official plain tcp symbol.
        glowcap_proc, port = start_glowcap_listener(work / "glowcap-server")
        try:
            result = subprocess.run(
                [str(client_binary), "127.0.0.1", str(port)], cwd=ROOT,
                text=True, capture_output=True, timeout=20,
            )
            if result.returncode or result.stdout.strip() != "Hello, world":
                write_log(work, "nim-to-glowcap.log", result.stdout + result.stderr)
                raise RuntimeError("Nim -> Glowcap invocation failed")
            print("PASS Nim -> Glowcap: bootstrap, fetch, invocation, promise")
        finally:
            glowcap_proc.terminate()
            try:
                glowcap_proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                glowcap_proc.kill()
                glowcap_proc.wait()

        # Unmodified Glowcap CLI -> Nim server over the same plain tcp profile.
        port = free_port()
        nim_server = subprocess.Popen(
            ["nim", "c", "-r", "--hints:off", "examples/native_greeter_server.nim",
             str(port)], cwd=ROOT, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        try:
            read_until(nim_server, "listening", 10)
            state = work / "glowcap-client"
            env = os.environ.copy()
            env["GLOWCAP_STATE"] = str(state)
            run_checked([str(GLOWCAP), "--json", "init"], env=env, timeout=10)
            uri = f"ocapn://127.0.0.1%3A{port}.tcp"
            output = run_checked(
                [str(GLOWCAP), "--json", "ocapn", "call", uri,
                 "nim-greeter", "greet", "world"], env=env, timeout=20)
            value = json.loads(output)["value"]
            if value != "Hello from Nim, world":
                raise RuntimeError("unexpected Glowcap -> Nim result: " + value)
            print("PASS Glowcap -> Nim: bootstrap, fetch, invocation, promise")
        finally:
            nim_server.terminate()
            try:
                nim_server.wait(timeout=3)
            except subprocess.TimeoutExpired:
                nim_server.kill()
                nim_server.wait()

        print("UNSUPPORTED Glowcap CLI: explicit handoff/pipelining matrix")
        print("UNVERIFIED Glowcap: TLS/Noise and Onion profiles")
        return 0
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        failures.append(str(error))
        print("FAIL interopTest")
        print(error, file=sys.stderr)
        print(f"diagnostics: {work}", file=sys.stderr)
        return 1
    finally:
        if failures:
            print(f"diagnostics preserved: {work}", file=sys.stderr)
        else:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
