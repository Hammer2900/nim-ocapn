{.compile: "glowcap_client.c".}
{.passC: "-I../../../glowcap/zig-out/include".}
{.passL: "-L../../../glowcap/zig-out/lib -Wl,-rpath,../../../glowcap/zig-out/lib -Wl,-l:libglowcap_driver.so.0.1.7 -Wl,-l:libglowcap_host.so.0.1.7 -Wl,-l:libglowcap_net_transport_tcp.so.0.1.7 -Wl,-l:libglowcap_ocapn.so.0.1.7".}

import std/[os, strutils]

proc nim_glowcap_greet(locator, name, output: cstring; outputCap: culong): cint
  {.importc, header: "glowcap_client.h".}

let locator = if paramCount() > 0: paramStr(1) else: ""
var output = newString(255)
let rc = nim_glowcap_greet(locator.cstring, "greeter".cstring, output.cstring, output.len.culong)
if rc != 0:
  stderr.writeLine("glowcap FFI failed: ", output)
  quit(1)
echo output.split('\0', maxsplit = 1)[0]
