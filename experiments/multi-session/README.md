# Multiple TCP sessions

The selector-backed `TcpSessionManager` accepts and drives multiple Nim
sessions in one process. Each accepted connection receives its own Session,
Ed25519 session seed, reference tables, publications, and pending promises.

Run the server:

```sh
nim c examples/native_multi_server.nim
./examples/native_multi_server 42016
```

Run both clients concurrently:

```sh
GLOWCAP_STATE=/tmp/glowcap-multi-a glowcap --json ocapn call \
  'ocapn://127.0.0.1%3A42016.tcp' nim-greeter greet alice &
GLOWCAP_STATE=/tmp/glowcap-multi-b glowcap --json ocapn call \
  'ocapn://127.0.0.1%3A42016.tcp' nim-greeter greet bob &
wait
```

Both calls complete independently. The server's selector loop removes closed
slots and invokes `Session.close()`, which breaks pending promises and clears
the per-session reference tables.
