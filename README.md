# nim-ocapn

> A standalone Nim implementation of the Object Capability Network (OCapN)
> protocol.

[![Nim 2.x](https://img.shields.io/badge/Nim-2.x-FFE953?logo=nim)](https://nim-lang.org/)
[![Version](https://img.shields.io/badge/version-1.0.0rc1-5B8CFF)](./nimocapn.nimble)
[![Status](https://img.shields.io/badge/status-beta-orange)](./CHANGELOG.md)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](./nimocapn.nimble)

**Navigation:** [Overview](#overview) · [Quick start](#quick-start) ·
[Features](#features) · [Protocol baseline](#protocol-specification--versioning) ·
[Interoperability](#interoperability) · [Transports](#transports--security) ·
[Testing](#testing) · [Documentation](#documentation)

---

## Overview

OCapN is a distributed object-capability model: applications exchange
references to objects rather than ambient names or global authority. CapTP is
the protocol layer that establishes sessions, invokes remote capabilities,
settles promises, transfers references, and accounts for distributed
references. Syrup is the canonical data representation used by the wire
protocol.

`nim-ocapn` provides these pieces as an independent Nim library for building
distributed applications:

- durable node identity and CapTP sessions;
- remote capabilities, promises, pipelining, handoff, and lifecycle cleanup;
- OCapN locators and sturdy references;
- testing TCP, Tor Onion, and a project-specific mutual-TLS profile;
- bounded polling, diagnostics, cancellation, and resource limits.

It is a protocol library, not an actor framework, mailbox runtime, scheduler,
VM, persistence layer, or Goblins port.

## At a glance

| Property | Current profile |
| --- | --- |
| Language | Nim 2.x |
| Package version | `1.0.0rc1` (`v1.0.0-rc.1` candidate) |
| Protocol baseline | Pinned OCapN and Syrup draft revisions; see [baseline](#protocol-specification--versioning) |
| Serialization | Syrup with canonical framing and strict test vectors |
| Transports | TCP testing-only, Tor Onion testing-only, project-specific mutual TLS |
| Runtime dependencies | None for the core library |
| Development status | Beta candidate; local release gate passed |
| Independent interoperability | Glowcap two-way bootstrap/invocation; selected Nim→Goblins scenarios |

> [!WARNING]
> Raw TCP and Tor Onion are unverified/testing profiles. The mutual-TLS path
> is a project-specific authenticated profile, not an official standardized
> OCapN Netlayer. Do not infer production security from a successful test call.

---

## Quick start

The package is currently installed from a fixed Git commit or a tagged local
checkout. Nimble 0.26.2 rejects the hyphenated `v1.0.0-rc.1` tag when it is
passed as an `@version` selector. The verified commit installation is:

```sh
nimble install 'https://github.com/Hammer2900/nim-ocapn.git@1b5d1ec1f0d107a792f0743e09b2963ac2fa4159'
```

To install exactly from the release tag with Nimble 0.26.2, clone the tag and
install the resulting checkout:

```sh
git clone --branch v1.0.0-rc.1 https://github.com/Hammer2900/nim-ocapn.git
nimble install file:///absolute/path/to/nim-ocapn
```

The following uses the public `nimocapn` facade and the public `syrup` value
module. It creates a persistent identity, publishes a greeter, connects to a
peer, bootstraps the capability, invokes it, and closes the node.

```nim
import std/[net, os]
import nimocapn
import syrup

var config = defaultNodeConfig(Port(42030))
config.identityPath = getEnv("NIM_OCAPN_IDENTITY", "server.identity")
config.netlayer = nlkTcpTestingOnly
config.verificationPolicy = testingOnlyPeerPolicy

let node = newNode(config)
node.publish("greeter", proc(args: seq[SyrupValue]): SyrupValue =
  if args.len == 1 and args[0].kind == skString:
    text("Hello, " & args[0].data)
  else:
    raise newException(CatchableError, "greeter expects one string"))

echo node.locator().peerUri()
try:
  while true:
    discard node.poll(1000, 64)
finally:
  node.close()
```

The matching client connects, bootstraps `greeter`, calls `greet`, and exits:

```nim
import std/[net, os, strutils]
import nimocapn
import syrup

var config = defaultNodeConfig()
config.identityPath = getEnv("NIM_OCAPN_IDENTITY", "client.identity")
config.netlayer = nlkTcpTestingOnly
config.verificationPolicy = testingOnlyPeerPolicy

let node = newNode(config)
let peer = parsePeerUri(paramStr(1))
let session = node.connectUsing(peer, nlkTcpTestingOnly)
let greeter = node.bootstrap(session, "greeter")
let result = waitFor(session, greeter.call("greet", [text("world")]))
echo result.data
node.close()
```

Runnable versions are [`examples/simple_server.nim`](examples/simple_server.nim)
and [`examples/simple_client.nim`](examples/simple_client.nim). They include
bounded lifecycle handling and persistent identity configuration.

<details>
<summary>Run the examples from a checkout</summary>

```sh
nim c examples/simple_server.nim
nim c examples/simple_client.nim

NIM_OCAPN_IDENTITY=server.identity ./examples/simple_server 42030
NIM_OCAPN_IDENTITY=client.identity ./examples/simple_client 'ocapn://...'
```

The server prints the peer locator. Copy that locator to the client process.
TCP in this example is intentionally `tcp-testing-only`.
</details>

---

## Features

| Capability | Status |
| --- | --- |
| CapTP sessions and signed session establishment | Implemented and covered by local and Glowcap tests |
| Remote capabilities and bootstrap/fetch | Implemented; two-way Nim↔Glowcap bootstrap/invocation passes |
| Promise fulfillment, rejection, and pipelining | Implemented; Nim multi-peer and local conformance coverage |
| `op:listen` modes 1/2/3 | Local matrix covered; cross-peer mode selection remains partial |
| Capability handoff | Implemented with three-/four-node and concurrent Nim coverage |
| Distributed reference lifecycle and GC accounting | Implemented for tested profiles; independent-runtime coverage is incomplete |
| Sturdyrefs and locators | Implemented with strict and legacy compatibility cases |
| Persistent Ed25519 node identity | Implemented; reused in CapTP session identity across restart |
| Cancellation and timeouts | Implemented for local observation and cleanup; no remote execution cancellation claim |
| Diagnostics and resource limits | Implemented through `NodeConfig`, `DiagnosticSink`, and `Node.stats()` |

These statuses describe the Nim implementation. They do not imply that every
feature is supported by an independent peer or every transport.

## Protocol specification & versioning

OCapN and Syrup are evolving draft specifications. This library therefore
pins the exact upstream revisions used for its compatibility profile:

| Specification | Pinned revision | Role |
| --- | --- | --- |
| [OCapN](https://github.com/ocapn/ocapn) | `ebf68742a40a89fff4730886a8788c5fe1bc9b96` | CapTP, Locators, Netlayers, Model, and Notation drafts |
| [Syrup](https://github.com/ocapn/syrup) | `931fa528b8ddda976febba577fb09ee0726845d4` | Canonical data encoding and framing dependency |

`1.0.0rc1` is the version of this Nim library. It is not an OCapN
specification version, and this project does not claim an official stable
“OCapN v1.0” protocol release. A newer upstream commit is not adopted
automatically: changing the baseline requires review, updated vectors,
compatibility analysis, and interoperability checks. PATCH/MINOR/MAJOR release
decisions are based on the effect on this library's API and compatibility, not
merely on the existence of a new upstream commit.

See the complete evidence and content hashes in
[SPECIFICATION_BASELINE.md](docs/SPECIFICATION_BASELINE.md).

---

## Interoperability

Interoperability results are intentionally separated from Nim↔Nim tests.

| Peer or suite | Pinned version/revision | Result |
| --- | --- | --- |
| Glowcap | `0.1.7`, `ced95ae4d7a591441c062ca95e76dd75ea181c65` | Nim↔Glowcap bootstrap, invocation, and promise scenarios pass in both directions |
| Guile Goblins | `2771da67e80b5c2a9e4ed684f24f4f95428cb419` | Nim→Goblins bootstrap/sturdyref/invocation scenarios pass in the pinned harness |
| OCapN upstream test suite | `31f0b806108a55d76a6ede5af7e413818dfb9221` | Selected session, deliver, GC, listen, and handoff modules pass against Goblins |
| Goblins reconnect/cleanup | Same pinned Goblins revision | Incomplete/UNVERIFIED; the full repeated-session fixture is unsupported |
| Cross-peer `op:listen` modes 1/2/3 | External peer CLI limitations | PARTIAL/UNVERIFIED; local normative coverage exists |

The upstream suite running against Goblins is not, by itself, proof of
Nim↔Goblins support for every operation. See
[INTEROPERABILITY_MATRIX.md](docs/INTEROPERABILITY_MATRIX.md).

## Transports & security

| Transport | Authentication | Intended use | Limitations |
| --- | --- | --- | --- |
| Raw TCP (`nlkTcpTestingOnly`) | Unverified | Local tests and development | Unencrypted; no production channel security |
| Tor Onion (`nlkOnionTestingOnly`) | Routing only; unverified CapTP identity binding | Explicit Tor integration tests | Requires an external Tor daemon and Onion Services; no direct-TCP fallback |
| Mutual TLS (`nlkMutualTls`) | Project-specific certificate and CapTP-key binding | Authenticated Nim↔Nim profile | Not an official OCapN Netlayer; inbound unified TLS listener is not exposed by `Node` |

Transport selection is explicit. An authenticated path does not silently fall
back to TCP or Onion. Node's convenient listener is currently TCP-based;
Onion and mutual-TLS listener APIs remain lower-level integration paths.

## Configuration & diagnostics

```nim
import std/net
import nimocapn

var config = defaultNodeConfig(Port(42030))
config.identityPath = "node.identity"
config.netlayer = nlkTcpTestingOnly
config.verificationPolicy = testingOnlyPeerPolicy
config.maxActiveSessions = 256
config.handshakeTimeoutMs = 30_000

let node = newNode(config)
let snapshot = node.stats()
node.close()
```

Applications can configure persistent identity, exact or authenticated peer
verification policies, session and handoff limits, handshake deadlines, and a
typed `DiagnosticSink`. `Node.stats()` exposes active sessions, pending
promises, imports/exports, handoffs, forwarded references, gifts, and queued
bytes. Diagnostics never intentionally include private keys or capability
payloads.

See [PUBLIC_API_GUIDE.md](docs/PUBLIC_API_GUIDE.md) and
[DIAGNOSTICS_AND_LIMITS.md](docs/DIAGNOSTICS_AND_LIMITS.md).

---

## Testing

| Command | Scope |
| --- | --- |
| `nimble test` | Core Syrup, messages, locators, transports, sessions, handoff, and identity |
| `nimble complianceTest` | Strict Syrup and Locator vectors |
| `nimble identityTest` | Durable identity and peer verification |
| `nimble stressTest` | Sequential/concurrent handoff and disconnect stress |
| `nimble handoffFailureTest` | Replay, timeout, disconnect, and cleanup matrix |
| `nimble distributedGcTest` | Import/export and reference lifecycle |
| `nimble cancellationTest` | Call/handoff timeout and cancellation semantics |
| `nimble diagnosticsTest` | Diagnostic events and resource limits |
| `nimble publicApiTest` | Public Node facade and lifecycle |
| `nimble deploymentTest` | Clean example builds, restart, signals, ports, and identity errors |
| `nimble packagingTest` | Local `file://` installation and external consumer |
| `nimble tlsTest` | Project-specific mutual-TLS E2E |
| `nimble transportConformanceTest` | Common in-memory/TCP/TLS scenarios; Onion is conditional |
| `nimble interopTest` | Separate-process Glowcap interoperability |
| `nimble independentInteropTest` | Optional Guile Goblins/upstream-suite integration |

The ordinary library build needs Nim 2.x, Nimble, a C compiler, and platform
socket libraries. Python, Guile/Goblins, Glowcap, OpenSSL, and Tor are only
needed for their optional tests or transport profiles.

## Documentation

| Topic | Document |
| --- | --- |
| Public API | [docs/PUBLIC_API_GUIDE.md](docs/PUBLIC_API_GUIDE.md) |
| Deployment | [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) |
| Operations and limits | [docs/OPERATIONS.md](docs/OPERATIONS.md) · [docs/DIAGNOSTICS_AND_LIMITS.md](docs/DIAGNOSTICS_AND_LIMITS.md) |
| Specification baseline | [docs/SPECIFICATION_BASELINE.md](docs/SPECIFICATION_BASELINE.md) |
| Protocol compliance | [docs/PROTOCOL_COMPLIANCE.md](docs/PROTOCOL_COMPLIANCE.md) |
| Interoperability | [docs/INTEROPERABILITY_MATRIX.md](docs/INTEROPERABILITY_MATRIX.md) |
| Security | [docs/SECURITY_AUDIT.md](docs/SECURITY_AUDIT.md) |
| Roadmap | [docs/ROADMAP_TO_V1.md](docs/ROADMAP_TO_V1.md) |
| Release procedure | [docs/RELEASING.md](docs/RELEASING.md) |
| Troubleshooting | [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) |

## Project status & known limitations

`nim-ocapn` is a release candidate, not a declaration of complete OCapN
compliance. The local release gate passes. Basic Glowcap interoperability is
verified, but the separate 24/24 × 3 conformance runner is unavailable in
this checkout and remains UNVERIFIED, while
some cross-peer and transport scenarios remain partial or environment
dependent:

- the pinned OCapN and Syrup documents are drafts;
- external `op:listen` mode interoperability is not fully demonstrated;
- Goblins reconnect/cleanup coverage is incomplete;
- Tor Onion requires externally managed services and remains unverified;
- raw TCP and Onion are not production-secure transports;
- the mutual-TLS profile is project-specific and has limited independent-peer
  interoperability.

The library deliberately does not include an actor runtime, scheduler, VM,
persistence layer, reconnect recovery system, or production distributed GC
collector for arbitrary independent runtimes.

## License & acknowledgements

The package declares the **Apache-2.0** license in
[`nimocapn.nimble`](nimocapn.nimble). The project builds on and tests against:

- [OCapN specifications](https://github.com/ocapn/ocapn);
- [Syrup specification](https://github.com/ocapn/syrup);
- [Spritely Goblins](https://gitlab.com/spritely/goblins);
- [Glowcap](https://github.com/ocapn/glowcap).

This project is an independent Nim implementation and does not depend on
Goblins, Glowcap, or an actor VM at runtime.
