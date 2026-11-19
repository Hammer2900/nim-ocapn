# Deployment

## Required dependencies

`nim-ocapn` release candidate `v1.0.0-rc.1` (Nimble metadata uses the compatible
`1.0.0rc1` spelling) has no Nimble runtime dependencies. Building an application
requires Nim 2.x, Nimble, a C compiler and the platform socket libraries. A
compiled application does not require Nim or Python at runtime.

Optional components are profile-specific:

- OpenSSL and `-d:ssl` are required only for the project-specific mutual-TLS profile.
- A configured Tor daemon is required only for the Onion testing profile.
- Python, Guile and Goblins are used only by interoperability tests.
- Raw TCP is testing-only and unauthenticated.

## Clean installation

```sh
nimble install nimocapn
nim c examples/simple_server.nim
nim c examples/simple_client.nim
```

The first command applies once the package is published to the Nimble index.
For an unreleased checkout, add that checkout explicitly with
`nimble develop --add /absolute/path/to/nim-ocapn`. An installed application
needs no `NIM_PATH` or repository-relative import path. Identity files are
versioned, are not silently replaced on load errors, and should be owned by
the application user with restrictive permissions.

Application code imports the package facade:

```nim
import nimocapn
```

## Profiles

`nlkTcpTestingOnly` and `nlkOnionTestingOnly` are unverified profiles. The
mutual-TLS path is a project-specific authenticated profile, not an official
OCapN Netlayer claim. Select it explicitly and compile with `-d:ssl`; there is
no automatic fallback to TCP or Onion.

For the two-process example, start the server and copy its printed locator:

```sh
export NIM_OCAPN_IDENTITY=/var/lib/myapp/server.identity
./simple_server 42030
export NIM_OCAPN_IDENTITY=/var/lib/myapp/client.identity
./simple_client 'ocapn://...'
```
