# Nimble 0.26 splits cached package paths at the last hyphen; keep the
# prerelease marker attached to the numeric version so clean installs work.
version       = "1.1.0rc1"
author        = "NimOCPN contributors"
description   = "Minimal independent OCapN/CapTP implementation in Nim"
license       = "Apache-2.0"
srcDir        = "src"
skipDirs      = @[
  "tests", "examples", "experiments", "docs", ".git", ".github"
]
skipFiles     = @[
  "*.identity", "*.csv", "*.log", "tls_peer", "conformance_server"
]

task test, "Run NimOCPN tests":
  exec "nim c -r --hints:off tests/test_syrup.nim && nim c -r --hints:off tests/test_messages.nim && nim c -r --hints:off tests/test_locators.nim && nim c -r --hints:off tests/test_transport.nim && nim c -r --hints:off tests/test_onion.nim && nim c -r --hints:off tests/test_session.nim && nim c -r --hints:off tests/test_server.nim && nim c -r --hints:off tests/test_gifts.nim && nim c -r --hints:off tests/test_handoff.nim && nim c -r --hints:off tests/test_handoff_disconnect.nim && nim c -r --hints:off tests/test_api.nim && nim c -r --hints:off tests/test_identity.nim && nim c -r --hints:off tests/test_client_auth.nim"

task identityTest, "Run durable identity and peer verification tests":
  exec "nim c -r --hints:off tests/test_identity.nim && nim c -r --hints:off tests/test_client_auth.nim"

task clientAuthTest, "Run CapTP durable client identity binding tests":
  exec "nim c -r --hints:off tests/test_client_auth.nim"

task tlsTest, "Run the real two-process mutual-TLS CapTP profile test":
  exec "python3 tests/test_tls_e2e.py && python3 tests/test_tls_node_api.py"

task torTest, "Run the explicit Tor Onion integration test":
  exec "nim c -r --hints:off tests/test_onion_e2e.nim && nim c -r --hints:off tests/test_onion_handoff_e2e.nim"

task onionE2eTest, "Run an isolated real Tor v3 Onion E2E test":
  exec "python3 tests/test_onion_real_e2e.py"

task stressTest, "Run bounded lifecycle and handoff stress tests":
  exec "nim c -r --hints:off tests/test_handoff_stress.nim"

task handoffFailureTest, "Run deterministic handoff failure and replay tests":
  exec "nim c -r --hints:off tests/test_handoff_failure.nim"

task distributedGcTest, "Run distributed reference lifecycle tests":
  exec "nim c -r --hints:off tests/test_distributed_gc.nim"

task cancellationTest, "Run public call and handoff cancellation tests":
  exec "nim c -r --hints:off tests/test_cancellation.nim"

task interopTest, "Run two-way interoperability against an unmodified Glowcap peer":
  exec "python3 tests/test_interop.py"

task independentInteropTest, "Run the upstream OCapN suite against unmodified Goblins":
  exec "python3 tests/test_goblins_interop.py"

task advancedInteropTest, "Run bounded advanced scenarios against independent peers":
  exec "python3 tests/test_advanced_interop.py"

task transportConformanceTest, "Run transport-neutral CapTP scenarios":
  exec "nim c -r --hints:off tests/test_transport_conformance.nim && python3 tests/test_tls_e2e.py && if [ -n \"$NIM_OCAPN_ONION_SERVICE\" ]; then nim c -r --hints:off tests/test_onion_e2e.nim; else echo 'Onion transport: SKIP (NIM_OCAPN_ONION_SERVICE is not set)'; fi"

task complianceTest, "Run local strict Syrup and Locator compliance vectors":
  exec "nim c -r --hints:off tests/test_syrup.nim && nim c -r --hints:off tests/test_locators.nim"

task robustnessTest, "Run adversarial protocol and framing tests":
  exec "nim c -r --hints:off tests/test_robustness.nim"

task fuzzTest, "Run deterministic bounded Syrup mutation fuzzing":
  exec "nim c -r --hints:off tests/test_robustness.nim"

task resourceTest, "Run bounded resource and lifecycle tests":
  exec "nim c -r --hints:off tests/test_resource_lifecycle.nim"

task enduranceTest, "Run the extended resource lifecycle workload":
  exec "nim c -r -d:endurance --hints:off tests/test_resource_lifecycle.nim"

task concurrencyTest, "Run bounded concurrent protocol workload tests":
  exec "nim c -r --hints:off tests/test_concurrency.nim"

task publicApiTest, "Run the public identity and netlayer API tests":
  exec "nim c -r --hints:off tests/test_public_api.nim"

task diagnosticsTest, "Run structured diagnostics and resource limit tests":
  exec "nim c -r --hints:off tests/test_diagnostics.nim"

task deploymentTest, "Run clean-build and process lifecycle deployment tests":
  exec "python3 tests/test_deployment.py"

task packagingTest, "Run the isolated public package consumer smoke test":
  exec "python3 tests/test_packaging.py"
