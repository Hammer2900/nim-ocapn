#!/usr/bin/env python3
"""Run bounded three-process handoff, failure, GC, and reconnect checks."""

from __future__ import annotations

import selectors
import signal
import socket
import subprocess
import tempfile
import time
from pathlib import Path

from test_tls_e2e import certificate_fingerprint, make_certificates

ROOT = Path(__file__).resolve().parents[1]
TIMEOUT = 45.0


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def stop(process: subprocess.Popen[str] | None) -> None:
    if process is None or process.poll() is not None:
        return
    process.send_signal(signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def collect(process: subprocess.Popen[str] | None) -> list[str]:
    if process is None:
        return []
    if process.poll() is None:
        stop(process)
    output, _ = process.communicate(timeout=1)
    return [line for line in output.splitlines() if line.startswith("STATE ")]


def graceful(control: Path, role: str, process: subprocess.Popen[str] | None) -> None:
    (control / f"stop-{role}").write_text("stop\n")
    if process is not None:
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            stop(process)


def read_ready(process: subprocess.Popen[str], role: str, deadline: float) -> None:
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    try:
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError(f"{role} exited before readiness")
            if not selector.select(deadline - time.monotonic()):
                continue
            if process.stdout.readline().strip().startswith(f"READY {role} "):
                return
    finally:
        selector.close()
    raise RuntimeError(f"{role} did not announce readiness")


def wait_checkpoint(control: Path, name: str, processes: tuple) -> None:
    deadline = time.monotonic() + TIMEOUT
    marker = control / name
    while time.monotonic() < deadline:
        if marker.exists():
            return
        for role, process in processes:
            if process is not None and process.poll() is not None:
                stderr = process.stderr.read() if process.stderr else ""
                raise RuntimeError(f"{role} exited before {name}: {stderr}")
        time.sleep(0.01)
    raise RuntimeError(f"checkpoint timeout: {name}")


def wait_for_line(process: subprocess.Popen[str], expected: str) -> None:
    deadline = time.monotonic() + TIMEOUT
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    lines: list[str] = []
    try:
        while time.monotonic() < deadline:
            if process.poll() is not None:
                break
            if not selector.select(deadline - time.monotonic()):
                continue
            line = process.stdout.readline().strip()
            if line:
                lines.append(line)
                if line == expected:
                    return
    finally:
        selector.close()
    if process.poll() is not None:
        remaining, error = process.communicate(timeout=1)
        lines.extend(line.strip() for line in remaining.splitlines() if line.strip())
        if expected in lines:
            return
        stderr = error
    else:
        stderr = process.stderr.read() if process.stderr else ""
    raise RuntimeError(f"expected {expected!r}, got {lines!r}; stderr={stderr!r}")


def build_peer(directory: Path) -> Path:
    binary = directory / "three_node_handoff_peer"
    subprocess.run([
        "nim", "c", "--hints:off", f"--out:{binary}",
        "tests/three_node_handoff_peer.nim",
    ], cwd=ROOT, check=True)
    return binary


def run_protected_handoff(root: Path, mode: str = "trusted") -> None:
    binary = root / "protected_three_node_peer"
    subprocess.run([
        "nim", "c", "-d:ssl", "--hints:off", f"--out:{binary}",
        "tests/protected_three_node_peer.nim",
    ], cwd=ROOT, check=True)
    with tempfile.TemporaryDirectory(prefix="nim-ocapn-protected-handoff-") as name:
        files = make_certificates(Path(name))
        a_port, c_port = free_port(), free_port()
        server_fp = certificate_fingerprint(files["server"])
        client_fp = certificate_fingerprint(files["client"])
        a = subprocess.Popen([
            str(binary), "A", str(a_port), str(files["server"]),
            str(files["server-key"]), str(files["ca"]), client_fp,
        ], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        c = subprocess.Popen([
            str(binary), "C", str(c_port), str(a_port), str(files["client"]),
            str(files["client-key"]), str(files["ca"]), server_fp, client_fp,
            mode, "u" * 32 if mode == "unknown" else "c" * 32,
        ], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        b = None
        try:
            deadline = time.monotonic() + TIMEOUT
            read_ready(a, "A", deadline)
            read_ready(c, "C", deadline)
            b = subprocess.Popen([
                str(binary), "B", str(a_port), str(c_port), str(files["client"]),
                str(files["client-key"]), str(files["ca"]), server_fp, client_fp,
            ], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if mode == "trusted":
                try:
                    wait_for_line(b, "PROTECTED_B_PASS")
                except Exception as error:
                    time.sleep(2)
                    stop(c)
                    c_out, c_err = c.communicate(timeout=5)
                    raise RuntimeError(f"B failed: {error}; C stdout={c_out!r} stderr={c_err!r}")
                wait_for_line(c, "PROTECTED_C_PASS")
                if b.returncode not in (None, 0) or c.returncode not in (None, 0):
                    raise RuntimeError("protected handoff process exited unsuccessfully")
                print("protected three-node handoff: PASS (B/C authenticated independently)")
            else:
                wait_for_line(c, "PROTECTED_C_REJECTED")
                b.wait(timeout=5)
                if b.returncode == 0:
                    raise RuntimeError("unauthorized protected handoff unexpectedly succeeded")
                print(f"protected three-node {mode} rejection: PASS")
        finally:
            for process in (a, b, c):
                stop(process)
            for process in (a, b, c):
                if process is not None:
                    process.communicate(timeout=5)


def start_cluster(binary: Path, control: Path, count = 1):
    a_port, c_port = free_port(), free_port()
    a = subprocess.Popen([str(binary), "A", str(a_port), str(control)], cwd=ROOT,
                         text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    c = subprocess.Popen([str(binary), "C", str(c_port), str(control), str(count)],
                         cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    deadline = time.monotonic() + TIMEOUT
    read_ready(a, "A", deadline)
    read_ready(c, "C", deadline)
    b = subprocess.Popen([
        str(binary), "B", str(a_port), str(c_port), str(control), str(count),
    ], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return a, b, c


def close_cluster(control: Path, processes: tuple, hard: set[str] = set()) -> None:
    for role, process in processes:
        if role in hard:
            stop(process)
        else:
            graceful(control, role, process)
    for _, process in processes:
        stop(process)


def run_success(binary: Path, root: Path, count = 1, label = "success") -> None:
    control = root / f"{label}-{count}"
    control.mkdir()
    for name in ("continue-withdrawal", "continue-invocation",
                 "continue-release", "continue-a-invocation",
                 "continue-fetched", "continue-deposited",
                 "continue-b-withdrawal"):
        (control / name).write_text("continue\n")
    processes = start_cluster(binary, control, count)
    a, b, c = processes
    try:
        wait_for_line(b, "HANDOFF_PASS")
        wait_for_line(c, "THREE_NODE_PASS")
        if b.returncode not in (None, 0) or c.returncode not in (None, 0):
            raise RuntimeError("successful handoff process exited unsuccessfully")
        print(f"three-node handoff x{count}: PASS (independent A/B/C processes)")
    finally:
        close_cluster(control, (("A", a), ("B", b), ("C", c)))


def run_failure(binary: Path, root: Path, name: str, checkpoint: str,
                victim: str, hard: bool, release_checkpoint = False) -> None:
    control = root / name
    control.mkdir()
    processes = start_cluster(binary, control)
    a, b, c = processes
    process_map = {"A": a, "B": b, "C": c}
    try:
        if checkpoint in {"B_DEPOSITED0", "B_WITHDRAWAL_STARTED0"}:
            (control / "continue-fetched").write_text("continue\n")
        if checkpoint == "B_WITHDRAWAL_STARTED0":
            (control / "continue-deposited").write_text("continue\n")
        if checkpoint.startswith("C_"):
            for continue_name in ("continue-fetched", "continue-deposited",
                                  "continue-b-withdrawal"):
                (control / continue_name).write_text("continue\n")
        if checkpoint == "C_WITHDRAWAL_DONE":
            (control / "continue-withdrawal").write_text("continue\n")
        if checkpoint == "C_INVOCATION_DONE":
            (control / "continue-withdrawal").write_text("continue\n")
            (control / "continue-invocation").write_text("continue\n")
            (control / "continue-a-invocation").write_text("continue\n")
        if checkpoint == "C_INVOCATION_STARTED":
            (control / "continue-withdrawal").write_text("continue\n")
            (control / "continue-invocation").write_text("continue\n")
        wait_checkpoint(control, checkpoint, (("A", a), ("B", b), ("C", c)))
        action = "after invocation before release" if release_checkpoint else checkpoint
        if hard:
            stop(process_map[victim])
            mode = "SIGTERM"
        else:
            graceful(control, victim, process_map[victim])
            mode = "graceful"
        survivors = tuple((role, process) for role, process in process_map.items()
                          if role != victim)
        close_cluster(control, survivors)
        for role, process in process_map.items():
            for state in collect(process):
                print(f"{name} {role}: {state}")
        print(f"failure {name}: PASS ({action}, victim={victim}, mode={mode})")
    finally:
        for process in processes:
            stop(process)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="nim-ocapn-three-node-") as name:
        root = Path(name)
        binary = build_peer(root)
        run_success(binary, root)
        run_success(binary, root, 10)
        run_success(binary, root, 50)

        # Alternate graceful and process-termination paths so both cleanup
        # contracts are exercised without multiplying the bounded suite.
        scenarios = [
            ("before-deposit", "B_FETCHED0", "B", False, False),
            ("after-deposit", "B_DEPOSITED0", "B", True, False),
            ("during-withdrawal", "C_WITHDRAWAL_STARTED", "C", False, False),
            ("after-withdrawal", "C_WITHDRAWAL_DONE", "C", True, False),
            ("during-invocation-a", "C_INVOCATION_STARTED", "A", False, False),
            ("during-invocation-c", "C_INVOCATION_STARTED", "C", True, False),
            ("after-invocation", "C_INVOCATION_DONE", "C", True, True),
        ]
        for name, checkpoint, victim, hard, release_checkpoint in scenarios:
            run_failure(binary, root, name, checkpoint, victim, hard, release_checkpoint)

        run_success(binary, root, 1, "reconnect")
        print("three-node reconnect/session replacement: PASS")
        run_protected_handoff(root)
        run_protected_handoff(root, "unknown")
        run_protected_handoff(root, "unauth")
        return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"three-node failure suite: FAIL: {error}")
        raise SystemExit(1)
