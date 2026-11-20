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


def wait_for_bootstrap(process: subprocess.Popen[str], log: Path, label: str,
                       timeout: float = 90.0) -> bool:
    started = time.monotonic()
    print(f"[TOR] {label}: waiting for bootstrap", flush=True)
    deadline = started + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            return False
        if "Bootstrapped 100%" in log.read_text(errors="replace"):
            print(f"[TOR] {label}: bootstrap PASS in {time.monotonic() - started:.1f}s",
                  flush=True)
            return True
        time.sleep(0.25)
    print(f"[TOR] {label}: bootstrap TIMEOUT after {timeout:.0f}s", flush=True)
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


def start_socks_tor(tor: str, root: Path):
    data = root / "data"
    data.mkdir(mode=0o700, parents=True)
    socks_port = free_port()
    torrc = root / "torrc"
    torrc.write_text(
        f"DataDirectory {data}\n"
        f"SocksPort 127.0.0.1:{socks_port}\n"
        "ClientOnly 1\nRunAsDaemon 0\nLog notice stdout\n"
    )
    process, output = start_tor(tor, torrc, root / "tor.log")
    return process, output, socks_port


def _recv_exact(sock: socket.socket, size: int) -> bytes:
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise RuntimeError("SOCKS5 peer closed during readiness probe")
        data += chunk
    return data


def socks5_probe(host: str, socks_port: int, onion: str, target_port: int,
                 timeout: float = 5.0) -> tuple[bool, str]:
    """Check Onion reachability only; never sends a CapTP byte."""
    started = time.monotonic()
    try:
        with socket.create_connection((host, socks_port), timeout=timeout) as sock:
            sock.settimeout(timeout)
            sock.sendall(b"\x05\x01\x00")
            if _recv_exact(sock, 2) != b"\x05\x00":
                return False, "SOCKS5 method negotiation rejected"
            name = onion.encode("ascii")
            sock.sendall(b"\x05\x01\x00\x03" + bytes([len(name)]) + name +
                         target_port.to_bytes(2, "big"))
            reply = _recv_exact(sock, 4)
            if reply[1] != 0:
                return False, f"SOCKS5 CONNECT reply=0x{reply[1]:02x}"
            address_len = 4 if reply[3] == 1 else 16 if reply[3] == 4 else _recv_exact(sock, 1)[0]
            _recv_exact(sock, address_len + 2)
        return True, f"{time.monotonic() - started:.2f}s"
    except (OSError, RuntimeError) as error:
        return False, f"{type(error).__name__}: {error}"


def wait_for_onion_readiness(hostnames: list[str], socks_port: int,
                             target_port: int, timeout: float = 60.0) -> None:
    """Wait for descriptors/routes, with a separate short-lived SOCKS probe."""
    deadline = time.monotonic() + timeout
    pending = set(range(len(hostnames)))
    last_error = "not attempted"
    while pending and time.monotonic() < deadline:
        for index in list(pending):
            ok, detail = socks5_probe("127.0.0.1", socks_port, hostnames[index], target_port)
            if ok:
                pending.remove(index)
                print(f"[TOR] protected-readiness service={index} PASS ({detail})", flush=True)
            else:
                last_error = f"service={index} {detail}"
        if pending:
            time.sleep(0.25)
    if pending:
        raise RuntimeError(
            "protected three-node ENVIRONMENT TIMEOUT: SOCKS5 readiness "
            f"pending={sorted(pending)} last={last_error}")


def wait_for_local_listeners(local_ports: list[int], timeout: float = 10.0) -> None:
    """Confirm each Nim listener is reachable before probing Tor routing."""
    deadline = time.monotonic() + timeout
    pending = set(local_ports)
    last_error = "not attempted"
    while pending and time.monotonic() < deadline:
        for port in list(pending):
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                    pending.remove(port)
                    print(f"[TOR] local listener port={port} PASS", flush=True)
            except OSError as error:
                last_error = f"port={port} {type(error).__name__}: {error}"
        if pending:
            time.sleep(0.1)
    if pending:
        raise RuntimeError(
            "protected three-node ENVIRONMENT TIMEOUT: local listeners "
            f"pending={sorted(pending)} last={last_error}")


def tail_log(path: Path, lines: int = 20) -> str:
    if not path.is_file():
        return "<log unavailable>"
    return "\n".join(path.read_text(errors="replace").splitlines()[-lines:])


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
    label = "auth-failure" if expect_auth_failure else "connect-failure" if expect_failure else "authenticated"
    started = time.monotonic()
    print(f"[TOR] Nim {label}: start", flush=True)
    try:
        subprocess.run([str(binary)], cwd=ROOT, env=environment, check=True, timeout=90)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"Nim {label} timeout after {time.monotonic() - started:.1f}s") from error
    print(f"[TOR] Nim {label}: PASS in {time.monotonic() - started:.1f}s", flush=True)


def run_protected_multi_onion(tor: str, root: Path) -> None:
    print("[TOR] protected three-node: prepare services", flush=True)
    binary = root / "test_onion_handoff_e2e"
    subprocess.run(["nim", "c", "--hints:off", f"--out:{binary}",
                    "tests/test_onion_handoff_e2e.nim"], cwd=ROOT, check=True)
    service_data = root / "multi-service-data"
    service_data.mkdir(mode=0o700)
    local_ports = [free_port(), free_port(), free_port()]
    hidden_dirs = [root / f"hidden-{name}" for name in ("a", "b", "c")]
    for directory in hidden_dirs:
        directory.mkdir(mode=0o700)
    service_torrc = root / "multi-service.torrc"
    lines = [f"DataDirectory {service_data}\n", "SocksPort 0\n",
             "ClientOnly 0\nRunAsDaemon 0\nLog notice stdout\n"]
    for directory, local_port in zip(hidden_dirs, local_ports):
        lines += [f"HiddenServiceDir {directory}\n",
                  "HiddenServiceVersion 3\n",
                  f"HiddenServicePort 9045 127.0.0.1:{local_port}\n"]
    service_torrc.write_text("".join(lines))
    service_process, service_output = start_tor(
        tor, service_torrc, root / "multi-service.log")
    client_process = client_output = None
    try:
        if not wait_for_bootstrap(service_process, root / "multi-service.log",
                                  "protected-service"):
            raise RuntimeError("protected three-node ENVIRONMENT TIMEOUT: service bootstrap")
        hostnames: list[str] = []
        deadline = time.monotonic() + 45
        while len(hostnames) < 3 and time.monotonic() < deadline:
            hostnames = [path.read_text().strip().removesuffix(".onion")
                         for path in (directory / "hostname" for directory in hidden_dirs)
                         if path.is_file()]
            if len(hostnames) < 3:
                time.sleep(0.25)
        if len(hostnames) != 3:
            raise RuntimeError(
                "protected three-node ENVIRONMENT TIMEOUT: hostname publication")
        print(f"[TOR] topology service-pid={service_process.pid} "
              f"data={service_data} socks=service-internal/disabled", flush=True)
        for index, (hostname, local_port, directory) in enumerate(
                zip(hostnames, local_ports, hidden_dirs)):
            print(f"[TOR] topology node={chr(ord('A') + index)} "
                  f"onion={hostname}.onion virtual=9045 "
                  f"target=127.0.0.1:{local_port} data={directory}", flush=True)
        client_process, client_output, socks_port = start_socks_tor(
            tor, root / "multi-client")
        if not wait_for_bootstrap(client_process, root / "multi-client/tor.log",
                                  "protected-client"):
            raise RuntimeError("protected three-node ENVIRONMENT TIMEOUT: client bootstrap")
        print(f"[TOR] topology client-pid={client_process.pid} "
              f"socks=127.0.0.1:{socks_port}", flush=True)
        environment = os.environ.copy()
        readiness_file = root / "protected-listeners.ready"
        readiness_done = root / "protected-listeners.probed"
        environment.update({
            "NIM_OCAPN_TOR_SOCKS": "127.0.0.1",
            "NIM_OCAPN_TOR_SOCKS_PORT": str(socks_port),
            "NIM_OCAPN_ONION_A": hostnames[0],
            "NIM_OCAPN_ONION_B": hostnames[1],
            "NIM_OCAPN_ONION_C": hostnames[2],
            "NIM_OCAPN_ONION_A_PORT": str(local_ports[0]),
            "NIM_OCAPN_ONION_B_PORT": str(local_ports[1]),
            "NIM_OCAPN_ONION_C_PORT": str(local_ports[2]),
            "NIM_OCAPN_ONION_SERVICE_PORT": "9045",
            "NIM_OCAPN_ONION_TRACE": "1",
            "NIM_OCAPN_ONION_PROTECTED_ONLY": "1",
            "NIM_OCAPN_ONION_READINESS_FILE": str(readiness_file),
            "NIM_OCAPN_ONION_READINESS_DONE": str(readiness_done),
        })
        print("[TOR] protected three-node: run Nim A/B/C", flush=True)
        nim_process = subprocess.Popen([str(binary)], cwd=ROOT, env=environment,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       text=True)
        try:
            deadline = time.monotonic() + 30
            while not readiness_file.is_file() and time.monotonic() < deadline:
                if nim_process.poll() is not None:
                    break
                time.sleep(0.05)
            if not readiness_file.is_file():
                if nim_process.poll() is None:
                    nim_process.terminate()
                    try:
                        nim_process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        nim_process.kill()
                        nim_process.wait()
                output, _ = nim_process.communicate(timeout=1)
                raise RuntimeError("protected three-node ENVIRONMENT TIMEOUT: "
                                   "Nim listeners did not become ready\n" + output)
            wait_for_local_listeners(local_ports)
            try:
                wait_for_onion_readiness(hostnames, socks_port, 9045)
            except RuntimeError as error:
                print("[TOR] protected three-node service log tail:", flush=True)
                print(tail_log(root / "multi-service.log"), flush=True)
                print("[TOR] protected three-node client log tail:", flush=True)
                print(tail_log(root / "multi-client/tor.log"), flush=True)
                raise
            readiness_done.write_text("probed\n")
            try:
                output, _ = nim_process.communicate(timeout=180)
            except subprocess.TimeoutExpired as error:
                nim_process.kill()
                nim_process.wait()
                raise RuntimeError("protected three-node Nim runner timeout") from error
            if nim_process.returncode:
                raise RuntimeError("protected three-node Nim runner failed:\n" + output)
        finally:
            if nim_process.poll() is None:
                nim_process.terminate()
                try:
                    nim_process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    nim_process.kill()
                    nim_process.wait()
        print("[TOR] protected three-node: PASS", flush=True)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError("protected three-node Nim runner timeout") from error
    finally:
        stop(client_process, client_output)
        stop(service_process, service_output)


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
            print("[TOR] service: start", flush=True)
            service_process, service_output = start_tor(
                tor, service_torrc, root / "service.log")
            hostname = hidden_service / "hostname"
            if not wait_for_bootstrap(service_process, root / "service.log", "service"):
                print("Real Tor v3 Onion E2E: ENVIRONMENT TIMEOUT (service Tor did not bootstrap)")
                print((root / "service.log").read_text(errors="replace")[-4000:])
                return
            deadline = time.monotonic() + 30
            while not hostname.is_file() and time.monotonic() < deadline:
                time.sleep(0.25)
            if not hostname.is_file():
                print("Real Tor v3 Onion E2E: ENVIRONMENT TIMEOUT (service hostname was not created)")
                return
            service = hostname.read_text().strip().removesuffix(".onion")
            print(f"[TOR] service: hostname ready {service}", flush=True)

            for label, private_key in (("client-a", private_a), ("client-b", private_b)):
                client_root = root / label
                client_process, client_output, socks_port = start_client_tor(
                    tor, client_root, service, private_key)
                try:
                    if not wait_for_bootstrap(client_process, client_root / "tor.log", label):
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
                if not wait_for_bootstrap(client_process, client_root / "tor.log", "wrong-credential"):
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
            if not wait_for_bootstrap(service_process, root / "service-restarted.log", "service-restart"):
                raise RuntimeError("restarted service Tor did not bootstrap")
            client_root = root / "revoked-client"
            client_process, client_output, socks_port = start_client_tor(
                tor, client_root, service, private_a)
            try:
                if not wait_for_bootstrap(client_process, client_root / "tor.log", "revoked-client"):
                    raise RuntimeError("revoked-credential Tor client did not bootstrap")
                run_nim(binary, service, socks_port, service_port, expect_failure=True)
            finally:
                stop(client_process, client_output)
                client_process = client_output = None
            print("Real Tor v3 Onion routing + client authorization: PASS", flush=True)
            run_protected_multi_onion(tor, root)
        finally:
            stop(client_process, client_output)
            stop(service_process, service_output)


if __name__ == "__main__":
    main()
