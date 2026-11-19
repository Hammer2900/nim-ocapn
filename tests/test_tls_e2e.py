#!/usr/bin/env python3
"""Real two-process mutual-TLS CapTP regression for the project TLS profile."""

from __future__ import annotations

import hashlib
import os
import socket
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PEER = Path(tempfile.gettempdir()) / "nim-ocapn-tls-peer"


def run(command: list[str]) -> None:
    subprocess.run(command, cwd=ROOT, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def certificate_fingerprint(path: Path) -> str:
    der = subprocess.run(
        ["openssl", "x509", "-in", str(path), "-outform", "DER"],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    ).stdout
    return hashlib.sha256(der).hexdigest()


def make_certificates(directory: Path) -> dict[str, Path]:
    ca_key = directory / "ca.key"
    ca_cert = directory / "ca.pem"
    run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-keyout", str(ca_key), "-out", str(ca_cert), "-days", "1",
         "-subj", "/CN=NimOCPN Test CA"])
    ext = directory / "server.ext"
    ext.write_text("subjectAltName=DNS:localhost\n")
    result: dict[str, Path] = {"ca": ca_cert}
    for name, subject in (("server", "/CN=localhost"), ("client", "/CN=nim-client"),
                          ("mitm", "/CN=localhost")):
        key = directory / f"{name}.key"
        csr = directory / f"{name}.csr"
        cert = directory / f"{name}.pem"
        run(["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes",
             "-keyout", str(key), "-out", str(csr), "-subj", subject])
        command = ["openssl", "x509", "-req", "-in", str(csr), "-CA", str(ca_cert),
                   "-CAkey", str(ca_key), "-CAcreateserial", "-out", str(cert),
                   "-days", "1", "-sha256"]
        if name == "server":
            command += ["-extfile", str(ext)]
        run(command)
        result[name] = cert
        result[f"{name}-key"] = key
    untrusted_key = directory / "untrusted.key"
    untrusted_cert = directory / "untrusted.pem"
    run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-keyout", str(untrusted_key), "-out", str(untrusted_cert), "-days", "1",
         "-subj", "/CN=localhost"])
    result["untrusted"] = untrusted_cert
    result["untrusted-key"] = untrusted_key
    return result


def free_port() -> int:
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def run_pair(files: dict[str, Path], client_seed: str, expected_server_seed: str,
             server_cert: str = "server", client_cert: str = "client",
             expect_success: bool = True, expected_client_seed: str | None = None,
             expected_server_fingerprint: str | None = None) -> None:
    port = free_port()
    server_fp = certificate_fingerprint(files[server_cert])
    client_fp = certificate_fingerprint(files[client_cert])
    server = subprocess.Popen(
        [str(PEER), "server", str(port), str(files["server" if server_cert == "server" else server_cert]),
         str(files[f"{server_cert}-key"]), str(files["ca"]), client_fp,
         expected_client_seed or client_seed, "11" * 32],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    try:
        ready = server.stdout.readline() if server.stdout else ""
        if ready.strip() != "READY":
            raise AssertionError("TLS server did not become ready: " + ready)
        client = subprocess.run(
            [str(PEER), "client", str(port), str(files["client" if client_cert == "client" else client_cert]),
             str(files[f"{client_cert}-key"]), str(files["ca"]),
             expected_server_fingerprint or server_fp,
             expected_server_seed, client_seed],
            cwd=ROOT, text=True, encoding="utf-8", errors="replace",
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15,
        )
        if expect_success:
            if client.returncode != 0 or "PASS" not in client.stdout:
                server.terminate()
                server_out, server_err = server.communicate(timeout=5)
                raise AssertionError(
                    f"TLS E2E failed: client stdout={client.stdout} client stderr={client.stderr} "
                    f"server stdout={server_out} server stderr={server_err}")
        elif client.returncode == 0:
            raise AssertionError("TLS negative case unexpectedly succeeded")
    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()


def main() -> None:
    run(["nim", "c", "-d:ssl", "--hints:off", f"--out:{PEER}", "tests/tls_peer.nim"])
    with tempfile.TemporaryDirectory(prefix="nim-ocapn-tls-") as temp:
        files = make_certificates(Path(temp))
        server_seed = "11" * 32
        client_seed = "22" * 32
        run_pair(files, client_seed, server_seed)
        run_pair(files, client_seed, server_seed)
        run_pair(files, client_seed, "33" * 32, expect_success=False)
        run_pair(files, "33" * 32, server_seed, expect_success=False,
                 expected_client_seed=client_seed)
        run_pair(files, client_seed, server_seed, server_cert="mitm", expect_success=False,
                 expected_server_fingerprint=certificate_fingerprint(files["server"]))
        run_pair(files, client_seed, server_seed, server_cert="untrusted", expect_success=False,
                 expected_server_fingerprint=certificate_fingerprint(files["untrusted"]))
    print("TLS authenticated CapTP E2E: PASS")


if __name__ == "__main__":
    main()
