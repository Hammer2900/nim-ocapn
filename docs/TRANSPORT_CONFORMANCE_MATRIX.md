# Transport Conformance Matrix

The same local CapTP scenario body is in
`tests/test_transport_conformance.nim`. It runs over an in-memory pair and a
real raw TCP socket. The TLS profile is exercised by the existing two-process
`tests/tls_peer.nim` path, extended with the same supported application cases.
Onion uses the existing real-Tor test and is only run when its environment is
configured.

Security status is not inferred from protocol success: raw TCP and Onion are
testing/unverified profiles, while the project-specific mutual-TLS profile is
authenticated by certificate fingerprint and CapTP key binding.

| Scenario | In-memory | Raw TCP | Mutual TLS | Tor Onion |
|---|---:|---:|---:|---:|
| Session handshake | PASS | PASS | PASS | SKIP: no Onion environment |
| Bootstrap/fetch | PASS | PASS | PASS | SKIP |
| Remote invocation | PASS | PASS | PASS | SKIP |
| Promise fulfillment | PASS | PASS | PASS | SKIP |
| Promise rejection | PASS | PASS | PASS | SKIP |
| Promise pipelining | PASS | PASS | PASS | SKIP |
| Local cancellation and late callback | PASS | PASS | PASS | SKIP |
| Import/export GC | PASS | PASS | PASS | SKIP |
| Disconnect cleanup | PASS | PASS | PASS | SKIP |
| Reconnect | PASS via existing lifecycle tests | PASS via existing lifecycle tests | PASS: repeated authenticated pair | SKIP |
| Three/four-node handoff | PASS via handoff suites | PASS via handoff suites | UNSUPPORTED in current TLS peer harness | SKIP |

Commands:

```text
nimble transportConformanceTest
```

The command reports Onion as `SKIP` unless `NIM_OCAPN_ONION_SERVICE` is set.
It never treats that skip as a successful Onion run. Glowcap interoperability
is an independent-peer matrix and is not folded into this local transport
matrix.

## Scope and limits

The harness checks that transports preserve the existing Syrup/CapTP framing,
dispatch order, promise lifecycle, and reference cleanup. It does not claim
that raw TCP or Onion provide authenticated channels. The TLS implementation
is the documented project-specific `tls-mtls-v1` profile, not an official
OCapN production netlayer.
