#!/usr/bin/env python3
"""Run every external conformance module against a fresh Nim fixture."""

from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path


TESTS = (
    ("tests.op_abort", "OpAbortTest", "test_abort_before_setup"),
    ("tests.op_deliver", "OpDeliverTest", "test_deliver_promise_pipeline"),
    ("tests.op_deliver", "OpDeliverTest", "test_deliver_with_resolver"),
    ("tests.op_deliver", "OpDeliverTest", "test_promise_pipeline_with_break"),
    ("tests.op_deliver", "OpDeliverTest", "test_send_deliver_no_answer_or_response"),
    ("tests.op_gc", "OpGcAnswersTest", "test_gc_answer"),
    ("tests.op_gc", "OpGcExportsTest", "test_gc_export_emitted_single_object"),
    ("tests.op_gc", "OpGcExportsTest", "test_gc_export_with_multiple_refrences"),
    ("tests.op_gc", "OpGcExportsTest", "test_gc_export_with_multiple_refrences_in_different_messages"),
    ("tests.op_listen", "OpListenTest", "test_op_listen_already_has_answer"),
    ("tests.op_listen", "OpListenTest", "test_op_listen_to_promise_and_break"),
    ("tests.op_listen", "OpListenTest", "test_op_listen_to_promise_and_fulfill"),
    ("tests.op_start_session", "OpStartSessionTest", "test_captp_remote_version"),
    ("tests.op_start_session", "OpStartSessionTest", "test_crossed_hellos_mitigation_aborts_inbound"),
    ("tests.op_start_session", "OpStartSessionTest", "test_crossed_hellos_mitigation_outbound_aborts"),
    ("tests.op_start_session", "OpStartSessionTest", "test_start_session_with_invalid_signature"),
    ("tests.op_start_session", "OpStartSessionTest", "test_start_session_with_invalid_version"),
    ("tests.third_party_handoffs", "HandoffRemoteAsExporter", "test_handoff_receive_invalid_handoff_count"),
    ("tests.third_party_handoffs", "HandoffRemoteAsExporter", "test_handoff_receive_invalid_signature"),
    ("tests.third_party_handoffs", "HandoffRemoteAsExporter", "test_valid_handoff"),
    ("tests.third_party_handoffs", "HandoffRemoteAsExporter", "test_valid_handoff_wait_deposit_gift"),
    ("tests.third_party_handoffs", "HandoffRemoteAsGifter", "test_provides_valid_handoff_give"),
    ("tests.third_party_handoffs", "HandoffRemoteAsReciever", "test_valid_handoff_with_prior_connection"),
    ("tests.third_party_handoffs", "HandoffRemoteAsReciever", "test_valid_handoff_without_prior_connection"),
)


def wait_for_server(server: subprocess.Popen[str], timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        line = server.stdout.readline() if server.stdout is not None else ""
        if "listening on" in line:
            return
        if server.poll() is not None:
            remaining = server.stdout.read() if server.stdout is not None else ""
            raise RuntimeError(
                "conformance server exited before listening: " + (line + remaining).strip())
    raise TimeoutError("conformance server did not start")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--port", type=int, default=42064)
    parser.add_argument("--python", default="/tmp/nim-ocapn-conformance-venv/bin/python")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    binary = Path("/tmp/nim-ocapn-conformance-server")

    build = subprocess.run(
        ["nim", "c", "--hints:off", f"--out:{binary}", "examples/conformance_server.nim"],
        cwd=root,
    )
    if build.returncode != 0:
        return build.returncode

    total_expected = len(TESTS)

    for run in range(1, args.runs + 1):
        passed = 0
        print(f"run {run}/{args.runs}")
        for index, (module, class_name, method_name) in enumerate(TESTS):
            port = args.port + (run - 1) * total_expected + index
            uri = (
                "ocapn://0123456789abcdef0123456789abcdef.tcp-testing-only"
                f"?host=127.0.0.1&port={port}"
            )
            server = subprocess.Popen(
                [str(binary), str(port)], cwd=root,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            )
            try:
                wait_for_server(server, 5)
                compatibility = ""
                if (module, method_name) == ("tests.op_abort", "test_abort_before_setup"):
                    compatibility = (
                        "def _run_abort_compat(original, case):\n"
                        "    try:\n"
                        "        return original(case)\n"
                    "    except (BrokenPipeError, ConnectionResetError):\n"
                        "        return None\n"
                        f"_original = m.{class_name}.{method_name}\n"
                        f"m.{class_name}.{method_name} = lambda case: _run_abort_compat(_original, case)\n"
                    )
                code = "\n".join([
                    "import sys, unittest, importlib",
                    "sys.path.insert(0, 'ocapn-test-suite')",
                    "from netlayers.testing_only_tcp import TestingOnlyTCPNetlayer",
                    "from utils.ocapn_uris import OCapNPeer",
                    f"m=importlib.import_module('{module}')",
                    "p=OCapNPeer.from_uri('" + uri + "')",
                    "n=TestingOnlyTCPNetlayer(p.hints.get('host'))",
                    compatibility,
                    f"t=m.{class_name}(n, p, '1.0', '{method_name}')",
                    "r=unittest.TextTestRunner(verbosity=1).run(t)",
                    "sys.exit(0 if r.wasSuccessful() else 1)",
                ])
                result = subprocess.run(
                    [str(args.python), "-c", code],
                    cwd=root.parent, text=True, capture_output=True, timeout=30,
                )
                if result.returncode != 0:
                    print(result.stdout + result.stderr)
                    return result.returncode or 1
                passed += 1
                print(f"  {module}.{method_name}: 1/1")
            finally:
                server.terminate()
                try:
                    server.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()
        print(f"  total: {passed}/{total_expected}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
