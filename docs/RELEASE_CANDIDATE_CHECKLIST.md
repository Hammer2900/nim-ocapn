# Scoped v1.0 Release Candidate Checklist

Candidate: `v1.0.0-rc.1` (Nimble metadata: `1.0.0rc1`).

Status: **READY for a scoped release candidate**; not a claim of universal
OCapN v1.0 transport security.

## Verified features

- CapTP sessions with a fresh Ed25519 identity per independent Session.
- Durable Node identity storage and restart persistence.
- Syrup framing, canonical vectors, promises, pipelining, handoff, and
  session-local reference lifecycle.
- Cancellation and timeout semantics with late-answer cleanup.
- Raw TCP and in-memory transport regression coverage.
- Project-specific mutual TLS E2E with certificate pinning and CapTP-key
  binding, including the public inbound Node listener.
- Public `import nimocapn` consumer build, examples, bootstrap, invocation,
  reconnect, and cleanup.
- Bounded resource, robustness, GC, handoff-failure, and concurrency suites.
- Explicit P13 inbound mutual-TLS E2E: two independent clients, bootstrap,
  invocation, reconnect, and cleanup.

## Security guarantees

- `connectVerified` checks the exact current CapTP session public key and
  expected locator before capabilities are exposed.
- `connectMutualTls` requires `pvmAuthenticatedNetlayer` before opening a
  socket, validates the TLS peer certificate/fingerprint, and requires the
  configured transport identity to match the CapTP session key.
- Reconnect and handoff auxiliary Sessions authenticate independently.
- Authentication failures fail closed and do not silently downgrade to the
  testing-only policy.

These guarantees do not bind a durable Node identity to an ephemeral session
key unless the application supplies the project-specific out-of-band mapping.

## Unsupported or limited profiles

- Raw TCP is testing-only and provides no channel confidentiality.
- Tor Onion routing is testing-only/unverified; Onion Service ID ownership of a
  CapTP key is not cryptographically proven by the pinned specification.
- The mutual TLS profile is project-specific, not an official OCapN netlayer.
- The public TLS listener is available under `-d:ssl`; Onion inbound serving
  remains outside the public facade.
- Complete cross-peer advanced `op:listen`, handoff, pipelining, and
  distributed-GC interoperability is not established with all independent
  peers.

## Release blockers

| Item | Status | Classification |
|---|---|---|
| Scoped Nim↔Nim protocol behavior | PASS | READY |
| Public facade and external consumer install | PASS | READY |
| Project mutual TLS profile, inbound and outbound | PASS | READY with documented scope |
| Official universal authenticated OCapN netlayer | UNVERIFIED | OUT OF SCOPE |
| Onion Service ID to CapTP identity binding | UNVERIFIED | OUT OF SCOPE |
| Full independent advanced interoperability | PARTIAL | NON-BLOCKER for scoped beta; document limits |
| TLS inbound Node listener through public facade | PASS | Project-specific profile; blocking TLS handshake limitation remains an operational limitation |
| Glowcap 24/24 × 3 conformance runner | UNVERIFIED | Runner unavailable in the local checkout |

## Breaking changes and migration

- `Node.identity`, `Node.verificationPolicy`, and
  `Node.sessionIdentityMode` are no longer directly replaceable. Configure
  them with `NodeConfig`; read the public identity with `publicIdentity()`.
- The default session identity is per-session. Select
  `simLegacyDurable` explicitly only for legacy peers.
- `connectMutualTls` requires an authenticated-netlayer policy and accepts an
  optional explicit session seed for the existing out-of-band key mapping.
- Low-level Session, manager, handoff, and reference-table fields remain
  experimental and are not part of the v1 compatibility promise.

## Required local gate

Run from a clean checkout with Nim 2.x:

```text
nimble check
nimble test
nimble identityTest
nimble complianceTest
nimble robustnessTest
nimble fuzzTest
nimble resourceTest
nimble enduranceTest
nimble concurrencyTest
nimble distributedGcTest
nimble handoffFailureTest
nimble cancellationTest
nimble tlsTest
nimble packagingTest
nimble deploymentTest
nimble publicApiTest
nimble interopTest
nimble independentInteropTest
nimble advancedInteropTest
git diff --check
```

Glowcap and Goblins results must remain labelled by actual direction and
scenario. SKIP, UNSUPPORTED, and UNVERIFIED are not PASS.

## Versioning recommendation

The proposed tag is `v1.0.0-rc.1`; Nimble uses `1.0.0rc1` because this is the
accepted prerelease spelling for the installed Nimble version. Create neither
tag nor release automatically. A stable v1.0 requires a deliberate
compatibility freeze and a published security scope; it does not require
claiming the unsupported official netlayer or Onion binding.
