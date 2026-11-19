# Independent Interoperability Matrix

This matrix records runs against unmodified peers. Nim↔Nim tests are reported
elsewhere and are not evidence of independent interoperability.

The default Nim Node profile now uses a fresh CapTP Ed25519 key per Session.
The exact-key and authenticated-TLS rows below therefore refer to the current
session key, not the durable Node identity. Legacy peers that require a stable
wire key must be exercised explicitly with `simLegacyDurable`; no automatic
downgrade is performed.

The P9 local cycle regression (`tests/test_api.nim`, A→B→A capability
forwarding) is protocol-lifecycle evidence only; it is not an independent-peer
interoperability result.

## Peer baseline

| Peer | Revision | Runtime/profile | Transport |
|---|---|---|---|
| Glowcap | `ced95ae4d7a591441c062ca95e76dd75ea181c65`, release `0.1.7` | Glowcap CapTP v1/legacy hello profile | plain TCP |
| Guile Goblins | `2771da67e80b5c2a9e4ed684f24f4f95428cb419`, `v0.18.0-40-g2771da6` | OCapN/CapTP v1 test-suite harness | `tcp-testing-only` |
| OCapN test suite | `31f0b806108a55d76a6ede5af7e413818dfb9221` | upstream bootstrap/sturdyref and CapTP tests | Python 3 |
| OCapN specs | `ebf68742a40a89fff4730886a8788c5fe1bc9b96` | pinned draft reference | n/a |
| Syrup specs | `931fa528b8ddda976febba577fb09ee0726845d4` | pinned draft reference | n/a |

Glowcap was started as a separate process from its checkout binary. No external
source was changed. The reproducible runner is `nimble interopTest`.

## Results

| Scenario | Direction | Profile | Result | Evidence/limitation |
|---|---|---|---|---|
| Session establishment | Nim → Glowcap | legacy Glowcap TCP | PASS | `tests/test_interop.py` |
| Bootstrap/fetch | Nim → Glowcap | legacy Glowcap TCP | PASS | fetched remote capability |
| Remote invocation and promise | Nim → Glowcap | legacy Glowcap TCP | PASS | `Hello, world` |
| Session establishment | Glowcap → Nim | legacy Glowcap TCP | PASS | independent CLI process |
| Bootstrap/fetch | Glowcap → Nim | legacy Glowcap TCP | PASS | Nim greeter published |
| Remote invocation and promise | Glowcap → Nim | legacy Glowcap TCP | PASS | `Hello from Nim, world` |
| Reconnect/repeated sessions | Nim ↔ Glowcap | legacy Glowcap TCP | PASS | `tests/test_advanced_interop.py`, two sequential sessions with persistent Glowcap state |
| `op:listen` mode 1 | Nim ↔ Glowcap | external peer | UNVERIFIED | Glowcap source implements listeners, but its CLI/host test path does not expose mode selection |
| `op:listen` mode 2 | Nim ↔ Glowcap | external peer | UNVERIFIED | no reproducible external settling-only follow-up listen |
| `op:listen` mode 3 | Nim ↔ Glowcap | external peer | UNVERIFIED | no reproducible external shortening-or-settling scenario |
| Syrup golden/negative vectors | local | pinned strict profile | PASS | `nimble complianceTest` |
| Promise pipelining | both directions | external peer | UNSUPPORTED | Glowcap CLI runner exposes no reproducible pipeline command |
| Import/export GC | both directions | external peer | UNSUPPORTED | no independent CLI scenario |
| Handoff, 3/4 nodes | both directions | external peer | UNSUPPORTED | Glowcap CLI has no handoff harness |
| Concurrent handoff | both directions | external peer | UNSUPPORTED | no external fixture |
| Disconnect/reconnect and release | both directions | external peer | UNSUPPORTED | no bounded CLI fixture |
| Malformed protocol messages | both directions | external peer | UNVERIFIED | requires a peer fault driver |
| TLS/Noise/Onion interop | both directions | production transport | UNVERIFIED | Glowcap support was not found in the pinned checkout |
| Session establishment | Nim → Guile Goblins | Goblins OCapN test-suite | PASS | Independent Guile process accepted the Nim session; `nimble independentInteropTest` |
| Bootstrap/fetch | Nim → Guile Goblins | Goblins OCapN test-suite | PASS | Nim fetched Goblins' published sturdyref |
| Sturdyref parsing/resolution | Nim → Guile Goblins | Goblins OCapN test-suite | PASS | Fixed echo sturdyref resolved by the unmodified Goblins fixture |
| Remote invocation/fulfillment | Nim → Guile Goblins | Goblins OCapN test-suite | PASS | Nim invocation returned `nim-to-goblins` response |
| Session establishment | upstream suite → Guile Goblins | pinned OCapN suite | PASS | `tests.op_start_session` in an isolated Goblins process |
| Remote invocation/fulfillment | upstream suite → Guile Goblins | pinned OCapN suite | PASS | `tests.op_deliver` in an isolated Goblins process |
| GC answers/exports | upstream suite → Guile Goblins | pinned OCapN suite | PASS | `tests.op_gc` in an isolated Goblins process |
| `op:listen` fulfillment/break | upstream suite → Guile Goblins | pinned OCapN suite | PASS | `tests.op_listen` in an isolated Goblins process |
| Third-party handoff | upstream suite → Guile Goblins | pinned OCapN suite | PASS | `tests.third_party_handoffs` in an isolated Goblins process |
| Full upstream suite in one Goblins process | upstream suite → Guile Goblins | pinned OCapN suite | UNSUPPORTED | Fixture listener is unavailable after the first independent session; runner records this instead of treating connection refusals as protocol PASS |
| Repeated session while peer stays alive | Nim ↔ Guile Goblins | Goblins OCapN test-suite | PASS | Local SIGPIPE-safe wrapper keeps the pinned fixture alive for two independent Nim sessions |
| Restarted peer bootstrap/invocation | Nim → Guile Goblins | Goblins OCapN test-suite | PASS | Runner stops and starts two independent Goblins processes and invokes the published echo capability in both |
| Durable-identity reconnect | Nim ↔ Guile Goblins | Goblins OCapN test-suite | UNVERIFIED | `spawn-mycapn` creates the CapTP session key inside each process; the pinned TCP fixture exposes no persistent identity input |
| Per-session key rotation | Nim ↔ Nim | default strict profile | PASS | `tests/test_identity.nim`: independent Sessions and reconnects have distinct wire keys while `Node.publicIdentity()` remains stable |
| Strict `op:listen` modes 1/2/3 | Nim ↔ Guile Goblins | strict CapTP vs Goblins legacy listener profile | UNVERIFIED | Goblins 0.18 exposes the boolean `wants-partial` wire form, not selectable strict modes 1/2/3; upstream → Goblins listen remains a separate PASS |
| Promise pipelining | Nim ↔ Guile Goblins | CapTP v1 | UNVERIFIED | The pinned Goblins fixture has no bounded Nim-facing pipeline driver beyond the upstream suite |
| Cross-peer handoff | Nim ↔ Guile Goblins | CapTP v1 | UNVERIFIED | Handoff is exercised upstream → Goblins; no public Goblins fixture API exposes a Nim-originated handoff scenario |
| Distributed GC | Nim ↔ Guile Goblins | CapTP v1 | UNVERIFIED | Wire GC is covered upstream → Goblins; object lifetime is not observable from the Nim-facing fixture |
| Invalid sturdyref/disconnect cleanup | Nim ↔ Guile Goblins | Goblins OCapN test-suite | UNSUPPORTED | Upstream suite does not provide this exact bounded scenario |

The previous recursive delivery-release defect is fixed in `src/session.nim`:
resolver fulfillment values are retained by the promise and are not immediately
released as temporary callback imports. Ordinary nested application arguments
still participate in recursive release accounting.

## Reproduction

```text
nimble interopTest
nimble advancedInteropTest
GLOWCAP_BIN=/path/to/glowcap nimble interopTest
nimble independentInteropTest
GOBLINS_PRE_INST_ENV=/path/to/goblins/pre-inst-env nimble independentInteropTest
```

For the local Fedora build used for the recorded run, also set
`GOBLINS_GUILE=/path/to/guile3.0` and
`OCAPN_TEST_PYTHON=/path/to/python-with-cryptography-and-stem`; the runner
requires `Guile 3.x`, `guile-fibers`, `guile-websocket`, `guile-noise`, and the
Goblins-generated `pre-inst-env`. When the umbrella checkout contains the
prepared `.tools/guileroot` and `.tools/goblins-build`, the runner discovers
those local paths automatically; it never installs them globally.

If the Glowcap binary is absent, the command reports `SKIP`. A present peer that
fails readiness, invocation, or cleanup reports `FAIL` and preserves logs in
`/tmp/nim-ocapn-interop-*`.

`independentInteropTest` starts a small local SIGPIPE-safe wrapper around the
unmodified Goblins fixture as a separate process and runs the Nim client plus
isolated upstream modules. The wrapper only prevents a client-side close from
terminating the listener; it does not change Goblins protocol behavior.
The local run used Guile 3.0.9, Goblins
`2771da67e80b5c2a9e4ed684f24f4f95428cb419`, and test-suite
`31f0b806108a55d76a6ede5af7e413818dfb9221`. It reported PASS for the Nim
bootstrap/sturdyref/invocation path, a restarted-process invocation, and the
available isolated upstream modules. The fixture's in-process repeated-session
path is UNSUPPORTED and its durable identity is UNVERIFIED for the reasons in
the matrix. Missing unconfigured prerequisites report SKIP; configured startup
or protocol failures report FAIL.
