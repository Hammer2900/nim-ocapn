#!/usr/bin/env python3
"""Bounded deployment checks for the public examples.

This is intentionally a small process harness, not a second test framework.
"""

from __future__ import annotations

import os
import selectors
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TIMEOUT = 20.0


def run(cmd: list[str], *, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, cwd=ROOT, env=env, text=True, capture_output=True,
                          timeout=TIMEOUT, check=False)


def build_examples(out: Path) -> tuple[Path, Path]:
    server = out / "simple_server"
    client = out / "simple_client"
    for source, binary, cache in (
        (ROOT / "examples/simple_server.nim", server, out / "server-cache"),
        (ROOT / "examples/simple_client.nim", client, out / "client-cache"),
    ):
        result = run(["nim", "c", "--hints:off", f"--nimcache:{cache}",
                      f"--out:{binary}", str(source)])
        if result.returncode:
            raise RuntimeError(f"build failed for {source.name}:\n{result.stdout}\n{result.stderr}")
    return server, client


def read_line(process: subprocess.Popen[str], deadline: float) -> str:
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    try:
        while time.monotonic() < deadline:
            events = selector.select(max(0.0, deadline - time.monotonic()))
            if not events:
                break
            line = process.stdout.readline()
            if line:
                return line.rstrip("\n")
            if process.poll() is not None:
                break
    finally:
        selector.close()
    stderr = ""
    if process.stderr is not None:
        stderr = process.stderr.read()
    raise RuntimeError(f"server did not announce readiness (exit={process.poll()}): {stderr}")


def start_server(binary: Path, identity: Path, port: int) -> tuple[subprocess.Popen[str], str]:
    env = os.environ.copy()
    env["NIM_OCAPN_IDENTITY"] = str(identity)
    process = subprocess.Popen([str(binary), str(port)], cwd=ROOT, env=env,
                               text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    try:
        locator = read_line(process, time.monotonic() + TIMEOUT)
        if not locator.startswith("ocapn://"):
            raise RuntimeError(f"unexpected locator: {locator}")
        return process, locator
    except BaseException:
        stop_process(process)
        raise


def stop_process(process: subprocess.Popen[str], sig: int = signal.SIGTERM) -> None:
    if process.poll() is None:
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=TIMEOUT)
    if process.returncode not in (0, -signal.SIGINT, -signal.SIGTERM):
        stderr = process.stderr.read() if process.stderr is not None else ""
        raise RuntimeError(f"server exited with {process.returncode}: {stderr}")


def invoke(client: Path, locator: str, identity: Path) -> None:
    env = os.environ.copy()
    env["NIM_OCAPN_IDENTITY"] = str(identity)
    result = run([str(client), locator], env=env)
    if result.returncode or result.stdout.strip() != "Hello, world":
        raise RuntimeError(f"client failed ({result.returncode}):\n{result.stdout}\n{result.stderr}")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="nim-ocapn-deployment-") as name:
        temp = Path(name)
        server_bin, client_bin = build_examples(temp)
        server_identity = temp / "server.identity"
        client_identity = temp / "client.identity"

        first, locator = start_server(server_bin, server_identity, 0)
        port = int(locator.rsplit("port=", 1)[1])
        invoke(client_bin, locator, client_identity)
        stop_process(first, signal.SIGTERM)
        saved_identity = server_identity.read_bytes()

        second, locator = start_server(server_bin, server_identity, port)
        if server_identity.read_bytes() != saved_identity:
            raise RuntimeError("persistent identity changed across restart")
        invoke(client_bin, locator, client_identity)

        busy, _ = start_server(server_bin, temp / "busy.identity", port + 1)
        try:
            result = run([str(server_bin), str(port + 1)], env={**os.environ,
                          "NIM_OCAPN_IDENTITY": str(temp / "occupied.identity")})
            if result.returncode == 0:
                raise RuntimeError("occupied port was accepted")
        finally:
            stop_process(busy)
        stop_process(second, signal.SIGINT)

        identity_dir = temp / "identity-dir"
        identity_dir.mkdir()
        result = run([str(server_bin), "0"], env={**os.environ,
                      "NIM_OCAPN_IDENTITY": str(identity_dir)})
        if result.returncode == 0:
            raise RuntimeError("directory identity path was accepted")

    print("deploymentTest: PASS (clean build, invocation, restart, signals, port and identity failures)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"deploymentTest: FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
