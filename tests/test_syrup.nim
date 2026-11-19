import std/unittest
import ../src/[framing, syrup]

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

  test "golden vectors cover integer boundaries and UTF-8":
    check integerMagnitude("18446744073709551616").encoded() == "18446744073709551616+"
    check integerMagnitude("18446744073709551616", true).encoded() == "18446744073709551616-"
    check text("熊").encoded() == "3\"熊"
    check symbol("hämta").encoded() == "6'hämta"
    check bytes("\x00\xff").encoded() == "2:\x00\xff"
    check record(symbol("outer"), list(text("inner"), integer(-1)),
        setValue(symbol("z"), symbol("a"))).encoded() ==
      "<5'outer[5\"inner1-]#1'a1'z$>"

  test "decodes nested golden vectors and permitted whitespace":
    for wire in ["[<6'person5\"Alice30+t>{3\"age30+4\"name5\"Alice}]",
                 "{3\"age 12+ 4\"name 7\"Tabatha 7\"species 3\"cat}"]:
      discard decoded(wire)
    check decoded("3:cat").encoded() == "3:cat"
    check decoded("6\"björn").encoded() == "6\"björn"
    check decoded("#3+1+2+$").encoded() == "#1+2+3+$"

  test "rejects non-canonical or malformed scalar/container vectors":
    for wire in ["01+", "0-", "1x", "3:ab", "1\"\xff", "1'\xff",
                 "#1+1+$", "{1'a1'b1'a1'c}", "<>", "<1'a"]:
      expect SyrupError:
        discard decoded(wire)
    expect SyrupError:
      discard decoded("1:a1:b")

  test "streaming framing handles fragments, coalescing, and limits":
    var decoder = newFrameDecoder(8)
    check decoder.feed("4:").len == 0
    check decoder.feed("test8:") == @["test"]
    check decoder.feed("payload!") == @["payload!"]
    var limited = newFrameDecoder(4)
    expect FramingError:
      discard limited.feed("5:abcde")
    var malformed = newFrameDecoder()
    expect FramingError:
      discard malformed.feed("01:x")

  test "canonicalizes dictionaries and sets":
    let value = dict([
      pair(text("name"), text("Alice")),
      pair(text("age"), integer(30))
    ])
    check value.encoded() == "{3\"age30+4\"name5\"Alice}"
    check setValue(integer(3), integer(1), integer(2)).encoded() == "#1+2+3+$"
    check dict([pair(bytes("\xff"), integer(1)), pair(bytes("\x00"), integer(2))]).encoded() ==
      "{1:\x002+1:\xff1+}"

  test "deterministic nested values round-trip canonically":
    proc generatedValue(depth: int): SyrupValue =
      if depth == 0:
        list(text("root"), bytes("\x00\xff"), integerMagnitude("18446744073709551616"))
      else:
        case depth mod 3
        of 0:
          dict([pair(text("right"), generatedValue(depth - 1)),
                pair(text("left"), generatedValue(depth - 1))])
        of 1:
          setValue(generatedValue(depth - 1), text("leaf"), integer(int64(depth)))
        else:
          record(symbol("node"), generatedValue(depth - 1), list(text("tail")))
    for depth in 0 .. 8:
      let wire = generatedValue(depth).encoded()
      check decoded(wire).encoded() == wire

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
    for wire in ["3:ca", "3\"ab", "3'ab", "[1+", "{1'a}", "#1+2+"]:
      expect SyrupError:
        discard decoded(wire)
