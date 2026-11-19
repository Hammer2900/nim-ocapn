# Troubleshooting

An occupied port is a startup error; choose another port or stop the process.
An identity path must be readable or creatable as a file. Corrupt and
unsupported identity files are rejected rather than silently replaced.

For handshake failures, verify the locator, listener availability, selected
transport, and expected peer identity. Strict identity mismatch closes the
session before capabilities are exposed.

TLS requires Nim SSL support (`-d:ssl`) and the project-specific certificate,
trust, and expected CapTP identity settings. It is not an official OCapN
Netlayer. Raw TCP and Onion remain unverified and are not production-secure.

Onion integration requires `NIM_OCAPN_ONION_SERVICE` and a reachable Tor
daemon. Without the variable the test reports `SKIP`; with it set, connection
failure is `FAIL`. There is no direct-TCP fallback.

Use `node.stats()` and `NodeConfig.diagnosticSink` for limits and lifecycle
problems. Always call `node.close()` in `finally`, including startup failures.
Python, Guile, Goblins, Tor, and OpenSSL are optional test dependencies, not
library runtime dependencies.
