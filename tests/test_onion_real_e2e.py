#!/usr/bin/env python3
"""Run the Onion E2E test with a private, temporary Tor v3 service."""

from __future__ import annotations

import os
import shutil
import signal
import socket
import subprocess
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def wait_for_tor(process: subprocess.Popen[str], log: Path, hostname: Path) -> str | None:
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        if process.poll() is not None:
            return None
        if hostname.is_file() and "Bootstrapped 100%" in log.read_text(errors="replace"):
            return hostname.read_text().strip()
        time.sleep(0.25)
    return None


def stop(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    process.send_signal(signal.SIGTERM)
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def main() -> None:
    tor = shutil.which("tor")
    if tor is None:
        print("Real Tor v3 Onion E2E: SKIP (tor executable is unavailable)")
        return

    with tempfile.TemporaryDirectory(prefix="nim-ocapn-tor-") as temp:
        root = Path(temp)
        data = root / "data"
        hidden_service = root / "hidden-service"
        data.mkdir()
        hidden_service.mkdir()
        hidden_service.chmod(0o700)
        socks_port = free_port()
        service_port = free_port()
        torrc = root / "torrc"
        log = root / "tor.log"
        torrc.write_text(
            f"DataDirectory {data}\n"
            f"SocksPort 127.0.0.1:{socks_port}\n"
            f"HiddenServiceDir {hidden_service}\n"
            "HiddenServiceVersion 3\n"
            f"HiddenServicePort 9045 127.0.0.1:{service_port}\n"
            "ClientOnly 0\nRunAsDaemon 0\nLog notice stdout\n"
        )
        with log.open("w+") as output:
            process = subprocess.Popen(
                [tor, "-f", str(torrc)], stdout=output, stderr=subprocess.STDOUT,
                text=True,
            )
            try:
                service = wait_for_tor(process, log, hidden_service / "hostname")
                if service is None:
                    print("Real Tor v3 Onion E2E: SKIP (Tor did not bootstrap)")
                    print(log.read_text(errors="replace")[-4000:])
                    return
                binary = root / "test_onion_real_e2e"
                subprocess.run(
                    ["nim", "c", "--hints:off", f"--out:{binary}",
                     "tests/test_onion_real_e2e.nim"],
                    cwd=ROOT, check=True,
                )
                environment = os.environ.copy()
                environment.update({
                    "NIM_OCAPN_ONION_SERVICE": service,
                    "NIM_OCAPN_TOR_SOCKS": "127.0.0.1",
                    "NIM_OCAPN_TOR_SOCKS_PORT": str(socks_port),
                    "NIM_OCAPN_ONION_LOCAL_PORT": str(service_port),
                })
                subprocess.run([str(binary)], cwd=ROOT, env=environment, check=True,
                               timeout=90)
                print("Real Tor v3 Onion E2E: PASS")
            finally:
                stop(process)


if __name__ == "__main__":
    main()
