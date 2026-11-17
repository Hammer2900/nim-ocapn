# NimOCPN

Minimal independent OCapN/CapTP implementation in Nim 2.x.

## Current progress

### Phase 1 — Glowcap interoperability

The Glowcap C ABI and driver architecture were inspected. Nim 2.4.0 now calls
the official Glowcap CLI greeter over TCP and receives `Hello, world`. Exact
commands are recorded in
[`experiments/glowcap-ffi/README.md`](experiments/glowcap-ffi/README.md).

### Phase 2 — native Nim foundation

The first independent component is [`src/syrup.nim`](src/syrup.nim). It has no
external dependencies and currently supports booleans, arbitrary decimal
integer magnitudes, binary data, UTF-8 strings/symbols as byte payloads,
single/double floats, lists, dictionaries, records, and sets. Dictionaries and
sets are canonicalized by encoded-byte ordering.

[`src/messages.nim`](src/messages.nim) provides small typed constructors for
the draft wire shapes of session start, deliver, deliver-only, abort, listen,
and GC messages. [`src/references.nim`](src/references.nim),
[`src/promises.nim`](src/promises.nim), [`src/transport.nim`](src/transport.nim),
and [`src/session.nim`](src/session.nim) add a deliberately small in-memory
prototype. It passes a Nim↔Nim Greeter call and promise fulfillment.
`src/framing.nim` implements Glowcap's canonical decimal-length Syrup
byte-string framing, including fragmented/coalesced input and frame limits.
`src/crypto.nim` verifies Ed25519 through system OpenSSL. `session.nim`
supports the draft five-field hello and Glowcap's legacy structured hello,
including `<my-location>` signature verification. The TCP client uses an
unbuffered Nim socket, completes the reverse hello, fetches `greeter`, and
prints `Hello, world` against both the official Glowcap CLI and the C ABI TCP
host in [`experiments/glowcap-c-host/`](experiments/glowcap-c-host/).

The reverse direction also works: [`examples/native_greeter_server.nim`](examples/native_greeter_server.nim)
publishes `nim-greeter`, which the official Glowcap CLI can fetch and call.
Reproduction is documented in [`experiments/native-greeter/README.md`](experiments/native-greeter/README.md).

Run its tests with:

```sh
nimble test
```

The alpha package version is `0.1.0-alpha` (`nimocapn.nimble`). A public API
overview is in [`API.md`](API.md). Runnable public-API examples are
[`examples/api_server.nim`](examples/api_server.nim),
[`examples/api_client.nim`](examples/api_client.nim), and
[`examples/api_handoff.nim`](examples/api_handoff.nim):

```sh
nim c examples/api_server.nim
./examples/api_server 42030
nim c examples/api_client.nim
./examples/api_client 127.0.0.1 42030
nim c -r examples/api_handoff.nim
```

## Proposed next modules

Keep the protocol layers small and separate: `messages.nim` for CapTP values,
`references.nim`, `promises.nim`, and `locators.nim` for capability state and
sturdyref values, `session.nim` for
handshake/framing, and `transport.nim` for an interface plus an in-memory test
transport. Add `peer.nim` only when session/bootstrap behavior requires it.
Reference tables are now explicit and session-local: export/import positions
from different sessions cannot alias each other. Pending promises are tracked,
released on settlement, and broken when a transport disconnects. The test suite
also covers two simultaneous sessions using the same numeric capability
positions for different objects. A non-blocking multi-session TCP manager and
the [`native_multi_server.nim`](examples/native_multi_server.nim) example now
serve multiple clients through a selector. `Session.callPipelined(promise,
verb, args)` sends a real `desc:answer` call before the first promise is
resolved; the in-memory tests cover a factory returning a capability followed
by an immediate method call through that promise.
Settled answers are now released with `op:gc-answers`; imported capabilities
remain independently tracked until the application releases them.
Protocol, handshake, and transport exceptions close the affected session,
break its pending promises, and clear its per-session tables.
The TCP session manager has an integration test proving that a malformed peer
is removed while a simultaneous healthy peer continues through fetch and call.
Closing a session also closes its underlying transport; selector cleanup is
safe when a protocol error has already closed the socket.
The manager tests also cover a client disconnect while a promise is pending;
that promise is broken without affecting a second active client.
`newTcpSessionManager` expires peers that remain in handshake beyond its
30-second default (`handshakeTimeoutMs` can be tuned for tests or deployments).
Client fds are removed from the selector while being processed and registered
again only for live sessions, preventing epoll fd-reuse registration errors;
the TCP tests exercise repeated sequential connect/disconnect cycles.
The session tests also cover fragmented/incomplete frames, malformed framing,
and concurrent calls with independent promises.
They also cover the four-field `op:deliver` form used by the Python
conformance peer when both answer-position and resolve-me are false.
The external GC suite now passes for export deltas and answer collection.
The external listen suite also passes for pending, fulfilled, broken, and
already-settled promises.
The external abort, deliver, GC, listen, and start-session modules all pass
against the conformance fixture. The fixture publishes the sturdyref enlivener,
opens an outbound session before its peer hello when needed, and resolves both
crossed-hello directions using the specified public-identifier comparison.
Against the external `ocapn-test-suite`, valid, invalid, and crossed
`op:start-session` cases pass over the testing-only TCP netlayer.
The `third_party_handoffs` module passes 7/7 with a fresh fixture process.
Full discovery still needs fixture isolation between long-lived scenarios.

The higher-level `api.nim` module exposes `Node`, `publish`, `connect`,
`fetchCapability`, `call`, `waitFor`, `poll`, and `close` for applications that do not need to
construct CapTP records manually. The current pipeline implementation handles
chained calls that resolve to exported capabilities. Promise-valued results and
distributed reference GC remain later work.
`Node.connect` bounds the handshake loop with `maxPumps` (10,000 by default)
and closes the transport if the peer never completes negotiation.
The message layer has exact constructors and validation for the signed
handoff descriptors. Gift deposit/withdraw routing and both conformance
handoff directions are implemented; distributed GC remains later work.
Sturdyref decoding accepts the binary swiss-number representation emitted by
the conformance suite, and the fixture's inbound crossed-hello case now passes.
`src/handoff.nim` owns both handoff directions end to end: it reuses an
existing peer session when available, fetches remote capabilities, deposits
gifts, fulfills deferred answers with signed `desc:handoff-give`, and creates
signed `desc:handoff-receive` withdrawals. The conformance fixture only wires
this manager into its published actors and polling loop. Completed pending
operations are pruned during `pump`; `HandoffManager.close()` breaks unfinished
enliven answers and closes all manager-owned auxiliary sessions idempotently.
`verifySignatureEnvelope` checks the canonical encoded handoff-give object
against its Ed25519 public key before any future handoff routing consumes it.
`validHandoffGive` and `validHandoffReceive` reject malformed descriptor shapes,
invalid session/side identifiers, invalid peer locators, and empty gift IDs
before signature or routing work.
`verifyHandoffReceive` additionally checks the outer receive certificate using
the receiver key carried by the nested handoff-give.
Incoming delivery arguments apply this validation recursively and close the
affected session on malformed handoff values.
Handoff counts are tracked per session and replayed counts are rejected.
The receive certificate is also bound to the current session ID and remote side
ID, so a certificate for another exporter/receiver connection is rejected.
Session integration tests cover both acceptance of a correctly signed receive
certificate and rejection of a tampered one.
`gifts.nim` provides a transport-independent gift table for pending
deposit/withdraw operations, receiver-key checks, duplicate protection, and
cleanup. `Session.depositGift` and `Session.withdrawGift` expose that table at
the low-level session API; automatic bootstrap wiring remains a later handoff
step. Bootstrap `op:deliver-only` now accepts the specified `deposit-gift`
shape and stores the gift without a receiver key until withdrawal. The
bootstrap `withdraw-gift` path now verifies the signed receive certificate and
fulfills its CapTP answer from the gift table, including pending gifts.
Invalid withdraw certificates break only their answer and do not abort the
otherwise valid CapTP session.
Pending withdrawals bind the first receiver key and break waiters using a
different key, preventing an unauthorized pending claimant.
Successful withdrawal consumes a gift; later withdrawal attempts do not reuse
the same capability, while a new deposit starts a new gift lifecycle.
Disconnecting a session cancels only that session's pending gift waiters,
without clearing the manager-wide table or other clients' gifts.
TCP session managers share one gift table across their sessions, while each
session retains independent references, promises, and handshake state. Closing
one client does not clear the manager-owned gift table; manager shutdown does.
Sessions now retain both handshake public keys and expose deterministic
`localSideId`, `remoteSideId`, and `sessionId` values matching the conformance
suite's canonical SHA-256 derivation.

For actor-style applications, `Session.exportActor` and `publishActor` provide
a session-aware behavior that can send deliveries to capability arguments;
ordinary `exportObject`/`publishObject` behaviors remain request/response-only.
`Session.deliverCall` adds an outbound answer/resolver when an actor needs a
reply from another capability, including automatic answer GC after settlement.
`Node.enliven(sturdyRef)` performs a TCP handshake and bootstrap fetch, returning
a live `RemoteCapability`; `examples/sturdyref_client.nim` exercises this path.
`Node` owns a `HandoffManager`; `Node.poll()` pumps its auxiliary handoff
sessions and `Node.close()` closes them before shutting down the TCP manager.
`Node.poll(timeoutMs, maxWork)` defaults to a bounded 64 units of work and
uses round-robin cursors for outbound sessions. `Node.stats()` exposes active
sessions, pending promises, imports/exports, queued bytes, and pending handoffs.
Session limits cover frame size, pending promises, imports/exports, and bounded
TCP output queues; `HandoffLimits` separately bounds pending handoff work.
Applications can pass both limit objects to `newNode(...)` to configure these
budgets without using the lower-level TCP manager.
`startHandoffReceiver` returns a `HandoffReceipt` containing both the
settlement promise and the receiver session, so the imported capability is
called through the correct connection. `tests/test_handoff.nim` covers a real
three-peer A → B → C handoff followed by a method call on the transferred
object.
Applications can call `publishHandoffEnlivener()`, `receiveHandoff()`, and
`waitForHandoff()` without managing the handoff tables directly.
`valueArg()` and `capabilityArg()` provide a small typed argument layer for
`Node.call()`: same-session references use their normal descriptor, while a
reference from another live session is sent as a signed nested handoff-give.
For example, a receiving application can expose a typed endpoint without
handling Syrup descriptors:

```nim
nodeC.publishTyped("register", proc(session: Session;
    args: seq[ReceivedArgument]): SyrupValue =
  let monster = args[0].capability
  text("registered"))

discard nodeB.call(registerOnC, "register", [capabilityArg(monsterFromA)])
```
Repeated enlivening on one `Node` reuses the same session-local capability for
the same transport/designator/swiss-number identity; `Node.close` releases its
outbound sessions.
`locators.nim` also supports the draft `ocapn://` peer and `/s/<swiss-num>`
sturdyref URI forms with query hints.
Use `Node.forget(sturdyRef)` to close and remove one cached outbound session;
closed cache entries are discarded automatically on the next `enliven`.
[`examples/conformance_server.nim`](examples/conformance_server.nim) contains
the suite's Greeter, Echo, Car Factory, and TCP sturdyref-enlivener fixtures for focused interoperability
work. Sessions retain the remote locator needed for future crossed-session
arbitration. With the suite's temporary Python environment, run its delivery tests with:

```sh
nim c examples/conformance_server.nim
./examples/conformance_server 42064
/tmp/nim-ocapn-conformance-venv/bin/python ../ocapn-test-suite/test_runner.py \
  'ocapn://0123456789abcdef0123456789abcdef.tcp-testing-only?host=127.0.0.1&port=42064' \
  --test-module tests.op_deliver
```

The full external suite is best run with a fresh fixture per module, because
the upstream discovery runner shares netlayer state between test classes. The
isolated runner starts a fresh server and uses a distinct TCP port for every
test/run, then aggregates all 24 tests:

```sh
python3 experiments/run_conformance_isolated.py --runs 3
```

## Supported profile and security status

The alpha targets the CapTP/OCapN 1.0-style profile exercised by the local
conformance suite: canonical Syrup framing, `op:start-session`, Ed25519
`Ed25519_SHA256` identity verification, CapTP deliver/answer/GC operations,
and the tested third-party handoff descriptors. It also accepts Glowcap's
legacy structured hello for interoperability. The checked peers are Nim 2.4.0
and the Glowcap checkout used by this workspace; no immutable Glowcap release
tag is recorded in this umbrella checkout.

The TCP netlayer is explicitly `tcp-testing-only`. It is unencrypted and has
no production channel security, certificate authority, or authorization policy.
Do not deploy it as a production transport. Distributed GC, persistence, actor
runtime, scheduler, and VM integration are outside this alpha.

For a 30-minute local soak with four clients and CSV diagnostics:

```sh
nim c experiments/soak.nim
./experiments/soak 1800 4 soak-0.1.0-alpha.csv
```

The deterministic queue test is part of `nimble test`. To probe the actual
nonblocking loopback socket path against a peer that never reads:

```sh
nim c experiments/tcp_backpressure_probe.nim
./experiments/tcp_backpressure_probe
```

To inspect a bootstrap publication independently of the conformance runner:

```sh
nim c examples/fetch_swiss.nim
./examples/fetch_swiss 127.0.0.1 42064 gi02I1qghIwPiKGKleCQAOhpy3ZtYRpB
```

`examples/invoke_sturdyref.nim` separately invokes that enlivener and confirms
that it creates an outbound TCP session; crossed-hello arbitration remains a
separate multi-peer test.

Typical client-side use is:

```nim
let peer = newNode(port = Port(0))
let session = peer.connect("127.0.0.1", Port(42030))
let greeter = session.fetchCapability("greeter")
let result = session.waitFor(greeter.call("greet", [text("world")]))
```
