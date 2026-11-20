# Releasing a scoped release candidate

This procedure prepares a reproducible scoped release candidate using local commands,
without publishing or creating a tag.

1. Start from a clean Git checkout and verify the intended commit.
2. Use Nim 2.x, Nimble, a C compiler and system socket libraries. OpenSSL is
   optional and is needed only for `-d:ssl`; Tor, Python, Guile and Goblins are
   test-only dependencies.
3. Run:

   ```sh
   nimble check
   nimble test
   nimble complianceTest
   nimble identityTest
   nimble cancellationTest
   nimble diagnosticsTest
   nimble deploymentTest
   nimble packagingTest
   nimble transportConformanceTest
   git diff --check
   ```

4. Run Glowcap three times when its checkout and fixture dependencies are
   available. Record Tor and Goblins as `SKIP` or `UNSUPPORTED`, never as
   success, when their environments are absent.
5. Verify a local package install and external consumer:

   ```sh
   nimble install file:///absolute/path/to/nim-ocapn
   ```

   For a fixed Git commit after a remote is configured:

   ```sh
   nimble install 'https://example.invalid/nim-ocapn.git@<commit>'
   ```

   For Nimble 0.26.2, clone the candidate tag and use
   `nimble install file:///absolute/path/to/nim-ocapn`. A fixed commit can be
   installed with `https://...@<commit>`. The Git URL is a procedure template,
   not a command to run against an unconfigured remote.
6. Review `docs/BETA_RELEASE_CHECKLIST.md`, package exclusions, license, and
   `git status`. Ensure no identity files, certificates, logs, binaries or
   secrets are tracked.
7. For this candidate, change Nimble metadata to `1.1.0rc2`, commit the change,
   and create the Git tag `v1.1.0-rc.2` only in the separate release task. This
   preparation task does not create or push it. The candidate is not a claim of
   universal authenticated OCapN netlayer interoperability.
