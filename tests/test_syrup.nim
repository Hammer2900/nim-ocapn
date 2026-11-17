import std/unittest
import ../src/syrup

suite "Syrup codec":
  test "encodes scalar values":
    check bytes("cat").encoded() == "3:cat"
    check text("björn").encoded() == "6\"björn"
    check symbol("fetch").encoded() == "5'fetch"
    check integer(0).encoded() == "0+"
    check integer(-5).encoded() == "5-"
    check integerMagnitude("123456789012345678901234567890").encoded() == "123456789012345678901234567890+"
    check integer(low(int64)).encoded() == "9223372036854775808-"
    check boolean(true).encoded() == "t"
    check float64Value(1.5).encoded() == "D?\xf8\x00\x00\x00\x00\x00\x00"
    check decoded(float32Value(1.5).encoded()).encoded() == float32Value(1.5).encoded()

  test "canonicalizes dictionaries and sets":
    let value = dict([
      pair(text("name"), text("Alice")),
      pair(text("age"), integer(30))
    ])
    check value.encoded() == "{3\"age30+4\"name5\"Alice}"
    check setValue(integer(3), integer(1), integer(2)).encoded() == "#1+2+3+$"

  test "encodes records and lists":
    check record(symbol("person"), text("Alice"), integer(30), boolean(true)).encoded() ==
      "<6'person5\"Alice30+t>"
    check list(integer(1), integer(2), integer(3)).encoded() == "[1+2+3+]"

  test "decodes and preserves canonical wire values":
    for wire in ["3:cat", "6\"björn", "5'fetch", "5-", "[1+2+3+]", "{3\"age30+}", "#1+2+3+$", "<6'persont>"]:
      check decoded(wire).encoded() == wire

  test "rejects malformed input":
    expect SyrupError:
      discard decoded("0-")
    expect SyrupError:
      discard decoded("{1'a1'b1'a1'c}")
    expect SyrupError:
      discard decoded("3:ab")
