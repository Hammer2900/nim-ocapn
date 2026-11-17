# Nim ↔ Glowcap FFI experiment

Temporary Phase 1 experiment; it is not a dependency of the future native Nim
OCapN library.

## Result

The exact Glowcap pin is Zig **0.17.1**: `../glowcap/build.zig.zon` declares
`.minimum_zig_version = "0.17.1"`, and Glowcap CI pins the same version. The
official binary is installed locally at `.tools/zig-x86_64-linux-0.17.1/zig`.
Its SHA-256 matches Glowcap's checked-in checksum. System Zig 0.16.0 was not
changed.

With Zig 0.17.1, the official command succeeds:

```sh
cd ../glowcap
../../NimOCPN/.tools/zig-x86_64-linux-0.17.1/zig build quick-start
# 01: greeter fetched by name and called over an authenticated, encrypted OCapN session
```

The C SDK archives and headers are generated in `../glowcap/zig-out/{include,lib}`.
The complete package now succeeds, including iroh and WebRTC sidecars:

```text
c-sdk-pack: .../zig-out/release/glowcap-c-v0.1.7-x86_64-linux.tar.gz
c-sdk-pack-smoke: individual and combined static consumers and shared consumer passed
Build Summary: 132/132 steps succeeded
```

Cargo is installed through rustup (`rustc 1.100.0`, `cargo 1.100.0`), but its
bin directory must be present in PATH: `export PATH="$HOME/.cargo/bin:$PATH"`.
The complete CLI product additionally uses Deno 2.9.8, the Rust
`wasm32-unknown-unknown` target, and `wasm-bindgen` CLI 0.2.130.

## Real Nim network test

Build the temporary C-ABI server and Nim client from this directory:

```sh
gcc -std=c11 -I../../../glowcap/zig-out/include glowcap_server.c \
  -L../../../glowcap/zig-out/lib -Wl,-rpath,../../../glowcap/zig-out/lib \
  -Wl,-l:libglowcap_driver.so.0.1.7 \
  -Wl,-l:libglowcap_host.so.0.1.7 \
  -Wl,-l:libglowcap_net_transport_tcp.so.0.1.7 \
  -Wl,-l:libglowcap_ocapn.so.0.1.7 -o glowcap-server
nim c --hints:off client.nim
./glowcap-server &
./client 'ocapn://127.0.0.1%3A46659.tcp'
# Hello, world
```

The same Nim client was also tested against the official Glowcap CLI listener:

```sh
export PATH="$HOME/.cargo/bin:$HOME/.deno/bin:$PATH"
GLOWCAP_STATE=/tmp/glowcap-official-a ./glowcap/zig-out/bin/glowcap --json init
GLOWCAP_STATE=/tmp/glowcap-official-a ./glowcap/zig-out/bin/glowcap \
  --json ocapn listen --publish greeter
# copy the printed locator, then run ./client '<locator>'
# Hello, world
```

The server uses Glowcap's C ABI to publish `greeter`; Nim calls `fetch`, sends
`greet("world")`, drives the driver loop, and decodes the remote completion.
This is genuine network OCapN interoperability over the local cleartext TCP
testing netlayer, not a production transport.

## Files and limitation

`client.nim` is the Nim FFI entry point. `glowcap_client.c` is a small ABI
bridge because the generated C structs and driver lifecycle are verbose.
`glowcap_server.c` is only a reproducible peer fixture. The future Nim library
must independently implement Syrup, CapTP state, references, promises, and
transport-neutral session handling; it must not depend on Glowcap.
