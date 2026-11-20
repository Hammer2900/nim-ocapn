#!/usr/bin/env python3
"""Run real Tor v3 routing and client-authorization checks in isolation."""

from __future__ import annotations

import base64
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


def run(command: list[str]) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(command, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def wait_for_bootstrap(process: subprocess.Popen[str], log: Path) -> bool:
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        if process.poll() is not None:
            return False
        if "Bootstrapped 100%" in log.read_text(errors="replace"):
            return True
        time.sleep(0.25)
    return False


def stop(process: subprocess.Popen[str] | None, output) -> None:
    if process is not None and process.poll() is None:
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    if output is not None:
        output.close()


def start_tor(tor: str, torrc: Path, log: Path):
    output = log.open("w")
    process = subprocess.Popen(
        [tor, "-f", str(torrc)], stdout=output, stderr=subprocess.STDOUT, text=True,
    )
    return process, output


def x25519_private_public(directory: Path, name: str) -> tuple[str, str]:
    pem = directory / f"{name}.pem"
    run(["openssl", "genpkey", "-algorithm", "X25519", "-out", str(pem)])
    private = run(["openssl", "pkey", "-in", str(pem), "-outform", "DER"]).stdout[-32:]
    public = run([
        "openssl", "pkey", "-in", str(pem), "-pubout", "-outform", "DER",
    ]).stdout[-32:]
    encode = lambda value: base64.b32encode(value).decode().rstrip("=")
    return encode(private), encode(public)


def ed25519_seed_public(directory: Path, name: str) -> tuple[str, str]:
    pem = directory / f"{name}.pem"
    run(["openssl", "genpkey", "-algorithm", "ED25519", "-out", str(pem)])
    seed = run(["openssl", "pkey", "-in", str(pem), "-outform", "DER"]).stdout[-32:]
    public = run([
        "openssl", "pkey", "-in", str(pem), "-pubout", "-outform", "DER",
    ]).stdout[-32:]
    encode = lambda value: base64.b64encode(value).decode()
    return encode(seed), encode(public)


def write_client_auth(directory: Path, service: str, private_key: str) -> Path:
    directory.mkdir(mode=0o700, parents=True)
    path = directory / "client.auth_private"
    path.write_text(f"{service}:descriptor:x25519:{private_key}\n")
    path.chmod(0o600)
    return path


def start_client_tor(tor: str, root: Path, service: str, private_key: str):
    data = root / "data"
    auth = root / "client-auth"
    data.mkdir(mode=0o700, parents=True)
    write_client_auth(auth, service, private_key)
    socks_port = free_port()
    torrc = root / "torrc"
    torrc.write_text(
        f"DataDirectory {data}\n"
        f"SocksPort 127.0.0.1:{socks_port}\n"
        f"ClientOnionAuthDir {auth}\n"
        "ClientOnly 1\nRunAsDaemon 0\nLog notice stdout\n"
    )
    process, output = start_tor(tor, torrc, root / "tor.log")
    return process, output, socks_port


def run_nim(binary: Path, service: str, socks_port: int, local_port: int,
            expect_failure = False, expect_auth_failure = False,
            client_seed = "", trusted_keys = "") -> None:
    environment = os.environ.copy()
    environment.update({
        "NIM_OCAPN_ONION_SERVICE": service,
        "NIM_OCAPN_TOR_SOCKS": "127.0.0.1",
        "NIM_OCAPN_TOR_SOCKS_PORT": str(socks_port),
        "NIM_OCAPN_ONION_LOCAL_PORT": str(local_port),
        "NIM_OCAPN_ONION_EXPECT_FAILURE": "1" if expect_failure else "",
        "NIM_OCAPN_ONION_EXPECT_AUTH_FAILURE": "1" if expect_auth_failure else "",
        "NIM_OCAPN_CLIENT_SEED_B64": client_seed,
        "NIM_OCAPN_TRUSTED_CLIENT_KEYS_B64": trusted_keys,
    })
    subprocess.run([str(binary)], cwd=ROOT, env=environment, check=True, timeout=300)


def main() -> None:
    tor = shutil.which("tor")
    if tor is None or shutil.which("openssl") is None:
        print("Real Tor v3 Onion E2E: SKIP (tor and openssl are required)")
        return

    with tempfile.TemporaryDirectory(prefix="nim-ocapn-tor-") as temp:
        root = Path(temp)
        binary = root / "test_onion_real_e2e"
        subprocess.run(
            ["nim", "c", "--hints:off", f"--out:{binary}",
             "tests/test_onion_real_e2e.nim"],
            cwd=ROOT, check=True,
        )

        service_data = root / "service-data"
        hidden_service = root / "hidden-service"
        authorized = hidden_service / "authorized_clients"
        service_data.mkdir(mode=0o700)
        hidden_service.mkdir(mode=0o700)
        authorized.mkdir(mode=0o700)
        service_port = free_port()
        service_torrc = root / "service.torrc"
        service_torrc.write_text(
            f"DataDirectory {service_data}\n"
            "SocksPort 0\n"
            f"HiddenServiceDir {hidden_service}\n"
            "HiddenServiceVersion 3\n"
            f"HiddenServicePort 9045 127.0.0.1:{service_port}\n"
            "ClientOnly 0\nRunAsDaemon 0\nLog notice stdout\n"
        )

        private_a, public_a = x25519_private_public(root, "client-a")
        private_b, public_b = x25519_private_public(root, "client-b")
        private_wrong, _ = x25519_private_public(root, "client-wrong")
        seed_a, cap_key_a = ed25519_seed_public(root, "cap-client-a")
        seed_b, cap_key_b = ed25519_seed_public(root, "cap-client-b")
        seed_unknown, _ = ed25519_seed_public(root, "cap-client-unknown")
        trusted_keys = f"{cap_key_a},{cap_key_b}"
        (authorized / "client-a.auth").write_text(f"descriptor:x25519:{public_a}\n")
        (authorized / "client-b.auth").write_text(f"descriptor:x25519:{public_b}\n")
        for path in authorized.iterdir():
            path.chmod(0o600)

        service_process = None
        service_output = None
        client_process = None
        client_output = None
        try:
            service_process, service_output = start_tor(
                tor, service_torrc, root / "service.log")
            hostname = hidden_service / "hostname"
            if not wait_for_bootstrap(service_process, root / "service.log"):
                print("Real Tor v3 Onion E2E: SKIP (service Tor did not bootstrap)")
                print((root / "service.log").read_text(errors="replace")[-4000:])
                return
            deadline = time.monotonic() + 30
            while not hostname.is_file() and time.monotonic() < deadline:
                time.sleep(0.25)
            if not hostname.is_file():
                print("Real Tor v3 Onion E2E: SKIP (service hostname was not created)")
                return
            service = hostname.read_text().strip().removesuffix(".onion")

            for label, private_key in (("client-a", private_a), ("client-b", private_b)):
                client_root = root / label
                client_process, client_output, socks_port = start_client_tor(
                    tor, client_root, service, private_key)
                try:
                    if not wait_for_bootstrap(client_process, client_root / "tor.log"):
                        raise RuntimeError(f"{label} Tor client did not bootstrap")
                    seed = seed_a if label == "client-a" else seed_b
                    run_nim(binary, service, socks_port, service_port,
                            client_seed=seed, trusted_keys=trusted_keys)
                    if label == "client-a":
                        run_nim(binary, service, socks_port, service_port,
                                expect_auth_failure=True, client_seed=seed_unknown,
                                trusted_keys=trusted_keys)
                finally:
                    stop(client_process, client_output)
                    client_process = client_output = None

            client_root = root / "wrong-client"
            client_process, client_output, socks_port = start_client_tor(
                tor, client_root, service, private_wrong)
            try:
                if not wait_for_bootstrap(client_process, client_root / "tor.log"):
                    raise RuntimeError("wrong-credential Tor client did not bootstrap")
                run_nim(binary, service, socks_port, service_port, expect_failure=True)
            finally:
                stop(client_process, client_output)
                client_process = client_output = None

            stop(service_process, service_output)
            service_process = service_output = None
            (authorized / "client-a.auth").unlink()
            service_process, service_output = start_tor(
                tor, service_torrc, root / "service-restarted.log")
            if not wait_for_bootstrap(service_process, root / "service-restarted.log"):
                raise RuntimeError("restarted service Tor did not bootstrap")
            client_root = root / "revoked-client"
            client_process, client_output, socks_port = start_client_tor(
                tor, client_root, service, private_a)
            try:
                if not wait_for_bootstrap(client_process, client_root / "tor.log"):
                    raise RuntimeError("revoked-credential Tor client did not bootstrap")
                run_nim(binary, service, socks_port, service_port, expect_failure=True)
            finally:
                stop(client_process, client_output)
                client_process = client_output = None
            print("Real Tor v3 Onion routing + client authorization: PASS")
        finally:
            stop(client_process, client_output)
            stop(service_process, service_output)


if __name__ == "__main__":
    main()
