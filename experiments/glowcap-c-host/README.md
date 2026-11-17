# Glowcap C ABI TCP peer

This experiment adapts the official `glowcap/examples/c/host_embedder_pump.c`
feed/pump/drain choreography to a small POSIX TCP listener. The C host owns the
Glowcap handshake, Syrup framing, bootstrap publication, and `greet` behavior;
the socket is the only code-specific transport layer.

Build the C peer against the already-built Glowcap SDK:

```sh
cc -std=c11 -Wall -Wextra -Werror \
  -I../../glowcap/zig-out/sdk/include tcp_greeter.c \
  -L../../glowcap/zig-out/sdk/lib \
  -Wl,-rpath,$PWD/../../glowcap/zig-out/sdk/lib \
  -lglowcap_host -lglowcap_ocapn -o tcp_greeter
```

Run `./tcp_greeter 42014`, then from `nim-ocapn/` run:

```sh
nim c examples/native_glowcap_client.nim
./examples/native_glowcap_client 127.0.0.1 42014
```

Expected output: `Hello, world`. The same Nim client also succeeds against the
official Glowcap CLI listener.
