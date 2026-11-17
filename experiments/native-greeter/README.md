# Nim-hosted Greeter

This example accepts one TCP CapTP session, publishes `nim-greeter`, and
answers calls from an official Glowcap peer.

Build and run the Nim server:

```sh
nim c examples/native_greeter_server.nim
./examples/native_greeter_server 42015
```

From another terminal, call it with Glowcap:

```sh
GLOWCAP_STATE=/tmp/glowcap-calls-nim glowcap --json ocapn call \
  'ocapn://127.0.0.1%3A42015.tcp' nim-greeter greet world
```

Expected result:

```json
{"ok":true,"value":"Hello from Nim, world"}
```

The server currently handles one session and implements only the minimal V1.0
bootstrap/fetch and method-call path.
