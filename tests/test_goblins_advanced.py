#!/usr/bin/env python3
"""Bounded Nim -> Goblins advanced CapTP driver."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from test_goblins_interop import local_goblins_runtime, start_peer, stop_peer


ROOT = Path(__file__).resolve().parents[1]
GOBLINS = Path(os.environ.get("GOBLINS_DIR", ROOT.parent / "goblins"))


def wait_for_file(path: Path, timeout: float, process: subprocess.Popen[str]) -> str:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            break
        if path.is_file():
            value = path.read_text(encoding="utf-8").strip()
            if value:
                return value
        time.sleep(0.05)
    raise RuntimeError(f"Nim reverse server readiness failed: {path}")


def run_reverse_pipeline(work: Path, pre_inst_env: Path, guile: str,
                         env: dict[str, str], scenario: str,
                         expected_marker: str) -> None:
    work.mkdir(parents=True, exist_ok=True)
    locator_file = work / "nim-reverse.locator"
    trace_file = work / "nim-reverse.trace"
    server_binary = work / "nim-reverse-pipeline-server"
    build = subprocess.run(
        ["nim", "c", "--hints:off", f"--out:{server_binary}",
         "tests/nim_pipeline_server.nim"],
        cwd=ROOT, text=True, capture_output=True, timeout=60,
    )
    if build.returncode:
        raise RuntimeError("Nim reverse server build failed:\n" + build.stdout + build.stderr)
    server_env = {**env, "NIM_OCAPN_PIPELINE_LOCATOR": str(locator_file),
                  "NIM_OCAPN_PIPELINE_TRACE": str(trace_file),
                  "NIM_OCAPN_REVERSE_SCENARIO": scenario}
    server = subprocess.Popen([str(server_binary)], cwd=ROOT, env=server_env,
                              text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT)
    peer = None
    try:
        locator = wait_for_file(locator_file, 10, server)
        peer_env = {**env, "GOBLINS_PIPELINE_MODE": "reverse",
                    "GOBLINS_REVERSE_SCENARIO": scenario,
                    "NIM_OCAPN_PIPELINE_LOCATOR": locator}
        peer, _ = start_peer(pre_inst_env, guile, ROOT / "tests" /
                             "goblins_pipeline_peer.scm", work, peer_env,
                             "reverse-pipeline")
        try:
            peer_output, _ = peer.communicate(timeout=30)
        except subprocess.TimeoutExpired as error:
            output = error.output or b""
            raise RuntimeError("Goblins reverse driver timeout:\n" +
                               (output.decode(errors="replace") if isinstance(output, bytes)
                                else str(output))) from error
        if peer.returncode or expected_marker not in peer_output:
            raise RuntimeError("Goblins reverse driver failed:\n" + peer_output)
        server.wait(timeout=5)
        if server.returncode:
            raise RuntimeError("Nim reverse server failed")
        trace = trace_file.read_text(encoding="utf-8") if trace_file.exists() else ""
        deliveries = [line for line in trace.splitlines() if " op:deliver " in line]
        pipeline_delivery = next((line for line in deliveries if "desc:answer:" in line), "")
        settled = next((line for line in trace.splitlines() if "promise:settle" in line), "")
        if not pipeline_delivery or not settled:
            raise RuntimeError("reverse trace lacks inbound op:deliver ordering:\n" + trace)
        print(f"PASS Goblins -> Nim ({scenario}): pipelined invocation before promise resolution")
        print("  evidence: " + pipeline_delivery + " | " + settled)
    finally:
        stop_peer(peer)
        if server.poll() is None:
            server.terminate()
            try:
                server.wait(timeout=3)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
        if server.stdout and server.poll() is not None:
            output = server.stdout.read()
            if output:
                print("  Nim reverse server: " + output.strip())
        if server.stdout:
            server.stdout.close()


def main() -> int:
    guile, pre_inst_env, env = local_goblins_runtime()
    fixture = GOBLINS / "tests" / "ocapn-test-suite.scm"
    script = ROOT / "tests" / "goblins_pipeline_peer.scm"
    missing = [str(path) for path in (fixture, script) if not path.is_file()]
    if guile is None:
        print("SKIP Guile 3.x is unavailable")
        return 0
    if not pre_inst_env.is_file():
        print(f"SKIP Goblins pre-inst-env is unavailable: {pre_inst_env}")
        return 0
    if missing:
        print("SKIP Goblins fixture prerequisites: " + ", ".join(missing))
        return 0

    work = Path(tempfile.mkdtemp(prefix="nim-ocapn-goblins-advanced-"))
    peer = None
    try:
        env["GOBLINS_UPSTREAM_FIXTURE"] = str(fixture)
        peer, locator = start_peer(pre_inst_env, guile, script, work, env, "pipeline")
        parsed = urlparse(locator)
        hints = parse_qs(parsed.query, keep_blank_values=True)
        host = hints.get("host", [""])[0]
        port = hints.get("port", [""])[0]
        if not host or not port:
            raise RuntimeError("Goblins locator has no host/port")

        binary = work / "goblins-pipeline-client"
        build = subprocess.run(
            ["nim", "c", "--hints:off", f"--out:{binary}",
             "tests/goblins_pipeline_client.nim"],
            cwd=ROOT, text=True, capture_output=True, timeout=60,
        )
        if build.returncode:
            raise RuntimeError(build.stdout + build.stderr)
        try:
            result = subprocess.run(
                [str(binary), host, port], cwd=ROOT, text=True,
                capture_output=True, timeout=30,
            )
        except subprocess.TimeoutExpired as error:
            raise RuntimeError(
                "Nim driver timeout\nstdout:\n"
                + str(error.stdout) + "\nstderr:\n" + str(error.stderr)
            ) from error
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        print("PASS Nim -> Goblins: pipelined invocation through unresolved promise")
        run_reverse_pipeline(work / "reverse-success", pre_inst_env, guile, env,
                             "success", "goblins-reverse-pipeline: PASS")
        run_reverse_pipeline(work / "reverse-reject", pre_inst_env, guile, env,
                             "reject", "goblins-reverse-pipeline: REJECTED PASS")
        run_reverse_pipeline(work / "reverse-repeated", pre_inst_env, guile, env,
                             "repeated", "goblins-reverse-pipeline: PASS")
        return 0
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print("FAIL Nim -> Goblins advanced driver: " + str(error))
        return 1
    finally:
        stop_peer(peer)
        if os.environ.get("KEEP_INTEROP_LOGS") != "1":
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
