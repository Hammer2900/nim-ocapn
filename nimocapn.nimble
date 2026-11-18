version       = "0.2.0-alpha"
author        = "NimOCPN contributors"
description   = "Minimal independent OCapN/CapTP implementation in Nim"
license       = "Apache-2.0"
srcDir        = "src"

task test, "Run NimOCPN tests":
  exec "nim c -r --hints:off tests/test_syrup.nim && nim c -r --hints:off tests/test_messages.nim && nim c -r --hints:off tests/test_locators.nim && nim c -r --hints:off tests/test_transport.nim && nim c -r --hints:off tests/test_onion.nim && nim c -r --hints:off tests/test_session.nim && nim c -r --hints:off tests/test_server.nim && nim c -r --hints:off tests/test_gifts.nim && nim c -r --hints:off tests/test_handoff.nim && nim c -r --hints:off tests/test_handoff_disconnect.nim && nim c -r --hints:off tests/test_api.nim"

task torTest, "Run the explicit Tor Onion integration test":
  exec "nim c -r --hints:off tests/test_onion_e2e.nim && nim c -r --hints:off tests/test_onion_handoff_e2e.nim"
