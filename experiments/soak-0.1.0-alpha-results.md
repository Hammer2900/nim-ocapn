# Alpha soak record

Command:

```sh
./experiments/soak 1800 4 soak-0.1.0-alpha.csv
```

The run used Nim 2.4.0, four client Nodes, one publishing server Node, one
handoff receiver Node, loopback TCP, 30-second CSV sampling, and reconnect plus
handoff cleanup every 256 calls. Resource fields were active sessions, pending
promises, imports, exports, pending handoffs, queued bytes, and Linux `VmRSS`.

The observed run was stopped by SIGINT after `1501.705` monotonic seconds, so it
is not a completed 1800-second soak. It recorded 36,456 calls and 142
reconnects. The final recorded row was:

```text
1501.7052760124207,36456,142,8,0,2,9,0,0,9008
```

No pending promises or queued bytes were observed in the final sample. Full
30-minute completion remains outstanding and must be run after this runner
change; SIGINT now follows the normal cleanup/final-CSV path.

The stopped run exposed a real descriptor leak: EOF marked a `TcpTransport` as
closed, and the later idempotent close skipped closing the underlying OS socket.
After fixing that split between logical and physical close, a 180-second smoke
run completed normally with 4,345 calls and 16 reconnects, and no selector
exhaustion. Glowcap conformance remained 24/24 in three consecutive runs.
