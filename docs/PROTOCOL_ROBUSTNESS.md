# Protocol Robustness

This document records the bounded input-hardening checks added for the P4
robustness batch. It is a test and implementation note, not a claim of formal
security certification.

## Decoder boundaries

- Syrup decoding rejects recursive values deeper than 255 nested containers.
  The bound is checked before descending, preventing attacker-controlled input
  from consuming an unbounded call stack.
- Frame decoding rejects non-positive configured limits, non-canonical length
  prefixes, integer overflow, frames larger than the configured limit, and
  incomplete bodies without allocating the advertised body.
- Fragmented, coalesced, zero-length, truncated, malformed, invalid UTF-8,
  and oversized frame/value inputs are covered by
  `tests/test_robustness.nim`.

## Session isolation

Malformed application operations and duplicate answer-GC positions close the
affected session and do not close an independent healthy session. Existing
session, handoff, cancellation, and distributed-GC suites remain the source
of truth for their respective lifecycle guarantees.

## Deterministic mutation checks

`nimble fuzzTest` runs the bounded Syrup, framing, and handoff-descriptor
mutation loop with a fixed seed and 2,000 inputs. It catches expected parser
errors while allowing defects or unrelated exceptions to fail the test. This
is a regression harness, not a coverage-guided fuzzer and not evidence that
all malformed inputs are safe.

The remaining risk areas are resource exhaustion across valid but numerous
protocol operations, hostile long-lived sessions, and security properties of
the testing-only TCP and Onion profiles.
