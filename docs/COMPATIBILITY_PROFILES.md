# Compatibility Profiles

The implementation currently has one runtime with two documented behavior
profiles. No automatic profile switch is introduced in Batch A.

## Strict OCapN Draft Profile

Target baseline: commits and hashes in
[`SPECIFICATION_BASELINE.md`](SPECIFICATION_BASELINE.md).

- Syrup String and Symbol values must contain valid UTF-8; invalid byte
  sequences are rejected.
- Dictionaries and sets reject duplicate members; encoding is canonicalized by
  encoded-byte ordering.
- Peer locators use `<ocapn-peer transport designator hints>` and sturdyrefs use
  `<ocapn-sturdyref peer swiss-num>` with a non-empty string swiss number.
- Locator equality is transport plus designator; hints are routing data.
- Unknown transport symbols are syntactically valid but cannot be dialled by a
  transport that does not implement them.
- URI parsers reject malformed percent escapes, fragments, duplicate decoded
  hint keys, and invalid UTF-8 produced by percent decoding.
- URI serialization preserves empty hint values as `key=` and sorts encoded
  hint keys for stable round-trips.
- Locator constructors reject invalid UTF-8 and empty sturdyref swiss numbers;
  Syrup dictionaries and sets reject duplicate members.
- Handoff and CapTP identity checks remain subject to the limitations in the
  protocol matrix; strict syntax is not a claim of production authentication.

Status: **PARTIAL**. Strict syntax and vector coverage is complete for the
pinned draft cases in this repository, but no explicit runtime profile
selector exists and secure netlayer identity binding is not implemented.

## Legacy / Glowcap Interoperability Profile

- `SturdyRef` accepts a binary swiss-number field as well as a String because
  the external Glowcap/conformance fixture emits that representation.
- The legacy structured four-field Glowcap hello remains accepted alongside the
  draft five-field hello.
- Inbound handoff gift IDs shorter than the strict 32-byte form remain accepted
  where required by the external fixture; Nim-generated IDs remain 32 bytes.
- The testing-only TCP transport remains available for the official external
  tests and is not a production security profile.

Status: **COMPLETE only for the tested interoperability fixture**, not for a
general strict/legacy negotiation protocol.

## Differences and consequences

| Difference | Normative basis | Current behavior | Explicit switch? | Consequence |
|---|---|---|---|---|
| Binary swiss number | Locators specifies String; fixture uses bytes | Accepted by `sturdyRef` | No | Preserves Glowcap; strict callers must validate String form |
| Legacy hello shape | External Glowcap profile | Accepted in `session.nim` | No | Broader interop; not a second normative CapTP revision |
| Short gift IDs | Handoff record requires 32-byte ID in draft | Legacy inbound compatibility | No | Must not be used as production authorization policy |
| UTF-8 String/Symbol | Syrup draft | Now rejected when invalid | No | Strict behavior is safe for valid peers |
| Malformed URI percent escapes | RFC 3986 URI form | Rejected by strict parser | No | Prevents ambiguous locator parsing |
| Duplicate URI/Syrup hint keys | Locator hints are a hashmap; Syrup dictionaries are unique | Rejected | No | Avoids silent last-value-wins normalization |
| Empty URI hint value | URI hint query uses `key=value` | Preserved as `key=` | No | Canonical URI round-trip retains the mapping |

No wire-format change was made for legacy compatibility. If a future strict
profile needs rejection of legacy values at runtime, add an explicit validated
decoder/profile boundary rather than silently normalizing messages.

## Independent peer evidence

`nimble interopTest` runs the pinned, unmodified Glowcap `0.1.7` binary as a
separate process in both directions over its plain TCP profile. Bootstrap,
fetch, invocation, and promise settlement pass. Glowcap's CLI does not expose
the handoff, pipelining, malformed-frame, or distributed-GC scenarios needed
for broader claims; those rows remain `UNSUPPORTED` or `UNVERIFIED` in the
[interoperability matrix](INTEROPERABILITY_MATRIX.md).
