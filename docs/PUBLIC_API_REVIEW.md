# Public API Review

## P2-13 public identity and transport facade

`NodeConfig`, `defaultNodeConfig`, `loadNodeIdentity`, `Node.locator`,
`Node.listenPort`, `Node.bootstrap`, and `Node.connectUsing` provide the
application-facing configuration path. Existing `newNode`, `dial`, `connect`,
`publish`, `fetchCapability`, and `close` remain compatible.

`nlkTcpTestingOnly` and `nlkOnionTestingOnly` are explicit unverified choices.
`nlkMutualTls` cannot silently select raw TCP; use `connectMutualTls` with
`-d:ssl` and a `TlsTransportConfig`. The Node listener is still TCP-based, so
inbound Onion/TLS serving remains a low-level transport operation.

## Batch B identity API

```nim
let identity = loadOrCreateIdentity("~/.config/my-node/identity.bin")
let node = newNode(port = Port(0), identity = identity)
echo node.publicIdentity()

let peer = node.connectVerified("127.0.0.1", Port(22045), expectedKey)
```

`createIdentity` refuses replacement unless `replaceExisting = true`.
`testingOnlyPeerPolicy` remains the default for backwards-compatible tests;
that mode is not peer authentication. When `identity` is passed to
`newNode`, accepted, outbound, and handoff Sessions all use that durable key
in their existing CapTP handshake. `authenticatedNetlayerPolicy` is fail-closed
until a production netlayer supplies a verified identity.

The public surface is in `src/api.nim`; low-level protocol access remains in
`session.nim`, `messages.nim`, and `references.nim`.

| User operation | Existing API | Assessment |
|---|---|---|
| Create a node | `newNode(NodeConfig)` or legacy `newNode(...)` | Durable identity path is available; legacy constructor remains testing-oriented when no identity is supplied |
| Publish capability | `node.publish`, `node.publishTyped` | Works; callbacks receive Syrup or typed arguments |
| TCP connect | `node.dial(host, port)` / `node.connect(host, port)` | Works; `connect` pumps the handshake with a bound |
| Locator connect | `node.connect(peer)` / `node.connectUsing(peer, kind)` | Works; explicit selection rejects transport mismatches and never downgrades |
| Fetch capability | `session.fetchCapability(name)` | Works; returns `RemoteCapability` |
| Call capability | `capability.call(verb, args)` or `node.call(...)` | Works; ordinary and typed argument paths exist |
| Promise wait | `session.waitFor`, `node.waitForHandoff` | Works for simple applications; application event-loop integration still needs manual `poll` |
| Promise pipelining | `promiseRef`, `promiseArg`, `callPipelined` | Works in tested Nim/multi-peer paths; API is lower-level than capability calls |
| Publish typed capability | `publishTyped` + `ReceivedArgument` | Works, including nested capability/promise arguments |
| Automatic handoff | `capabilityArg` through `node.call` | Works for tested live capabilities; no sturdyref is required |
| Sturdyref enlivening | `node.enliven`, `enlivenVia`, `forget` | Works over current profiles; authorization and durable identity are absent |
| Shutdown | `session.close`, `node.close` | Idempotent and tested |
| Diagnostics | `Node.stats`, `Session.stats`, trace sink | Works; no standardized metrics schema |

## Minimal example using existing names

```nim
let server = newNode(port = Port(42030), seedPrefix = "server")
server.publish("greeter", proc(args: seq[SyrupValue]): SyrupValue =
  text("Hello, " & args[0].data))

let client = newNode(port = Port(0), seedPrefix = "client")
let session = client.connect("127.0.0.1", Port(42030))
let greeter = session.fetchCapability("greeter")
let answer = greeter.call("greet", [text("world")])
discard session.waitFor(answer)
client.close()
server.close()
```

For an application event loop use `dial`, repeatedly call `node.poll(timeout,
maxWork)`, inspect the returned `Promise`, and close the node on shutdown.
`Node.connect` is convenient but pumps internally and is not a replacement for
an application scheduler.

## Remaining API gaps

1. No unified public `listen/accept` API for Onion or mutual TLS; current inbound use is
   transport-level and harness-oriented.
2. No cancellation token for an individual call or handoff; cleanup is tied to
   Session/Node close and resource limits.
3. `RemoteCapability` exposes its session/reference fields, so callers can drop
   to low-level descriptors; this is useful for tests but weakens encapsulation.
4. `waitFor` is bounded but synchronous; async integration with chronos remains
   deliberately outside this library.

These are API/design gaps, not reasons to add an actor runtime or scheduler.
