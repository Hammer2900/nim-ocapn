#!/usr/bin/env python3
"""Two-process inbound mutual-TLS test through the public Node facade."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

from test_tls_e2e import certificate_fingerprint, free_port, make_certificates, run


ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    peer = Path(tempfile.gettempdir()) / "nim-ocapn-tls-node-peer"
    run(["nim", "c", "-d:ssl", "--hints:off", f"--out:{peer}",
         "tests/tls_node_peer.nim"])
    with tempfile.TemporaryDirectory(prefix="nim-ocapn-tls-node-") as name:
        files = make_certificates(Path(name))
        port = free_port()
        server = subprocess.Popen(
            [str(peer), "server", str(port), str(files["server"]),
             str(files["server-key"]), str(files["ca"]),
             certificate_fingerprint(files["client"])],
            cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        try:
            ready = server.stdout.readline() if server.stdout else ""
            if ready.strip() != "READY":
                output, error = server.communicate(timeout=5)
                raise RuntimeError(
                    f"TLS Node server did not become ready: {ready!r}; "
                    f"stdout={output!r} stderr={error!r}")
            command = [str(peer), "client", str(port), str(files["client"]),
                       str(files["client-key"]), str(files["ca"]),
                       certificate_fingerprint(files["server"])]
            clients = [subprocess.Popen(command, cwd=ROOT, text=True,
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                       for _ in range(2)]
            results = [client.communicate(timeout=20) for client in clients]
            if any(client.returncode != 0 or "PASS" not in stdout
                   for client, (stdout, stderr) in zip(clients, results)):
                server.terminate()
                output, error = server.communicate(timeout=5)
                raise RuntimeError(
                    f"TLS Node API failed: clients={results!r}; "
                    f"server={output!r} {error!r}")
        finally:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
    print("TLS inbound public Node API: PASS")


if __name__ == "__main__":
    main()
