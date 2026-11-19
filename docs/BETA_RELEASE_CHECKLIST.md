# Beta release checklist

## READY

- [x] `nimble check` succeeds with Nim 2.4.0.
- [x] Public `nimocapn` entrypoint builds from an isolated source tree.
- [x] Unit, compliance, identity, cancellation, diagnostics and deployment
      tests pass.
- [x] No CapTP/Syrup wire changes are part of release preparation.
- [x] TCP/Onion limitations and the project-specific TLS profile are documented.
- [x] Local `file://` Nimble installation and external consumer invocation pass.

## BLOCKER

- None for local release preparation.

## PARTIAL

- [x] The documented local command sequence runs the supported suites and
      packaging smoke test.
- [x] Public examples perform a two-process call and restart cleanly.
- [x] Package excludes tests, examples, experiments, documentation and build
      artifacts from installed source payloads.
- [x] License and package metadata are present.
- [ ] P1-8 cross-peer `op:listen` modes 1/2/3 remain partial.
- [ ] P1-12 Goblins reconnect/cleanup and repeated-session coverage remain partial.

## UNVERIFIED

- [ ] Package installation from the Nimble registry: the package is not yet published.
- [ ] Tor Onion E2E with configured Onion Services.
- [ ] Git URL installation until a repository remote is available.

## OPTIONAL

- [x] Glowcap conformance 24/24 × 3.
- [ ] Mutual-TLS E2E when OpenSSL is available.

The candidate version is `v0.3.0-beta.1`; Nimble metadata uses `0.3.0beta1`.
This checklist does not create a tag or publish a package.
