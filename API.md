# Public API

`nim-ocapn` targets Nim 2.x and exposes a small independent CapTP/OCapN API.

## Node and sessions

```nim
let node = newNode(port = Port(42030), seedPrefix = "server")
let session = node.connect("127.0.0.1", Port(42030))
```

Use `dial()` for a non-blocking connection and call `node.poll(timeoutMs,
maxWork)` from the application event loop. `connect()` waits for the handshake
using the session pump and is convenient for a simple client.

## Publishing and calls

```nim
node.publish("greeter", proc(args: seq[SyrupValue]): SyrupValue =
  text("Hello, " & args[0].data))

let greeter = session.fetchCapability("greeter")
let answer = session.waitFor(greeter.call("greet", [text("world")]))
```

`publishTyped()` receives `ReceivedArgument` values. Capability arguments are
created with `capabilityArg()`; ordinary values use `valueArg()` or direct
Syrup values. `listArg`, `recordArg`, `dictArg`, and `setArg` preserve nested
capabilities.

Promise capabilities use `RemotePromise` and `promiseArg()`:

```nim
let pending = remoteFactory.call("makePromise", [])
let forwarded = nodeB.call(remoteRegister, "register",
  [promiseArg(promiseRef(sessionA, pending))])
```

The receiving typed handler gets `rakPromise` with a `RemotePromise`. Promise
identity, shortening, chained promises, and breaks are propagated across the
intermediate peer without application code handling descriptors or gift IDs.

## Automatic handoff

```nim
discard nodeB.call(registerOnC, "register", [capabilityArg(monsterFromA)])
```

The library selects the correct descriptor for same-session references and
creates an asynchronous handoff for capabilities from another session. The
application does not manage gift IDs, signed descriptors, or withdrawal.

## Lifecycle and errors

Call `node.poll()` regularly, inspect `node.stats()` for resource diagnostics
(including `listenerLifecycles`),
and call `node.close()` during shutdown. `Session.close()` and `Node.close()`
are idempotent. Disconnects break pending promises and clear session-local
reference tables. Protocol, framing, handshake, and resource-limit failures
close only the affected session and surface as `SessionError` or a broken
`Promise`.

`SessionLimits` and `HandoffLimits` can be passed to `newNode()`. Ownership is
session-local: retain imported capabilities while using them and release them
when finished; closing a session releases its remaining state.
