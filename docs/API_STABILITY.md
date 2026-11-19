# API Stability and Authentication Contract

`import nimocapn` is the supported application-facing entrypoint for the
`0.3.0beta1` beta. The facade is intentionally small and delegates protocol
state and cleanup to the existing runtime.

## Stable surface

The following operations are the intended stable API:

- `defaultNodeConfig`, `newNode`, `loadNodeIdentity`, `Node.publicIdentity`;
- `Node.publish`, `Node.publishTyped`, `Node.locator`, `Node.listenPort`;
- `Node.connect`, `Node.connectUsing`, `Node.connectVerified`;
- `Node.bootstrap`, `fetchCapability`, `RemoteCapability.call`;
- `waitFor`, `waitForCallTimeout`, `cancelCall`;
- `receiveHandoff`, `waitForHandoff`, `waitForHandoffTimeout`, `Node.cancel`;
- `Node.poll`, `Node.stats`, `Node.setDiagnosticSink`, and `Node.close`;
- `NodeConfig`, `SessionIdentityMode`, `NetlayerKind`, verification policies,
  diagnostics, limits, and documented error types.

`Session`, `Promise`, and capability values appear in these signatures because
they are required to wait for or invoke a remote operation. Their lifecycle is
owned by the associated Node/Session; callers must use the documented close,
wait, and cancellation procedures.

## Experimental surface

The low-level modules re-exported for protocol tests and unusual integrations
are not frozen for v1:

- mutable fields on `Session`, `TcpSessionManager`, `HandoffManager`,
  `RemoteCapability`, and `RemotePromise`;
- direct reference, promise, answer, listener, gift, and GC tables;
- raw `Transport` implementations and direct `newSession` constructors;
- direct handoff-manager and session registry operations.

These fields can bypass ownership, limits, verification, or cleanup invariants.
Applications should not modify them. They remain public in the beta to avoid a
large breaking change to protocol fixtures; a future v1 freeze may replace
them with read-only accessors.

## Authentication contract

| API | What is checked | What is not implied |
|---|---|---|
| `connect` / `connectUsing` TCP | handshake and protocol validity; testing-only policy by default | peer authentication, confidentiality, or durable Node identity |
| `connectUsing` Onion | requested Onion locator routing plus CapTP handshake | cryptographic Onion-Service-ID to CapTP-key binding |
| `connectVerified` | exact advertised CapTP **session** public key and expected locator | durable Node identity; reconnect reuse of the same key |
| `connectMutualTls` | mutual certificate/CA validation, pinned certificate fingerprint, configured CapTP session-key mapping | official OCapN netlayer status or automatic durable-identity binding |
| inbound listener | local policy and handshake verification before capabilities are exposed | authenticated transport for raw TCP listener |
| reconnect / handoff auxiliary Session | a new independent session handshake and its own policy check | inherited verification from an earlier Session |

The default `SessionIdentityMode.simPerSession` generates a fresh Ed25519 key
for every Session. `simLegacyDurable` is an explicit project-specific mode
for peers requiring the old durable wire key; it never activates implicitly.

## Compatibility changes before v1

P11 hides `Node.identity`, `Node.verificationPolicy`, and
`Node.sessionIdentityMode` from direct mutation. Configure them through
`NodeConfig` and use `publicIdentity()` for the public identity. The exported
`Node.manager` and `Node.handoffs` remain experimental compatibility surfaces
for existing low-level tests and integrations.

The `seed` arguments on low-level/session connection constructors are explicit
deterministic session-key overrides. Normal Node calls leave them empty and
therefore use per-session random keys. Code that depended on a beta default
durable wire key must select `simLegacyDurable` explicitly.

This profile does not claim that raw TCP or Onion is safe for hostile Internet
deployment, and the project-specific TLS profile is not an official OCapN
authenticated netlayer.
