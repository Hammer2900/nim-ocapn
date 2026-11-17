## Minimal Nim FFI smoke test for the Glowcap OCapN archive.
##
## This is intentionally only an ABI/linkage probe. It does not claim network
## compatibility; the real experiment must add the driver and TCP provider.

type GlowcapHost {.importc: "GlowcapHost", header: "glowcap_host.h".} = object

proc glowcap_abi_version(major, minor, patch: ptr uint32) {.importc, header: "glowcap_ocapn.h".}
proc glowcap_host_new(
  seed: ptr uint8,
  seedLen: csize_t,
  frameCap: csize_t,
  verifyPartner: uint32,
  codec: uint32,
  captpVersion: uint32,
  features: uint32,
  localTurnBudget: uint32,
  releaseOnDrop: uint32,
  outHost: ptr ptr GlowcapHost
) : int32 {.importc, header: "glowcap_host.h".}
proc glowcap_host_release(host: ptr GlowcapHost): int32 {.importc, header: "glowcap_host.h".}

const GlowcapCodecSyrup = 1'u32
const GlowcapCaptpV1 = 0'u32

var major, minor, patch: uint32
glowcap_abi_version(addr major, addr minor, addr patch)
echo "Glowcap C ABI: ", major, ".", minor, ".", patch

var seed: array[64, uint8]
var host: ptr GlowcapHost
let rc = glowcap_host_new(
  addr seed[0], seed.len.csize_t, 1024 * 1024, 1, GlowcapCodecSyrup,
  GlowcapCaptpV1, 0, 0, 0, addr host
)
if rc != 0 or host.isNil:
  quit("glowcap_host_new failed: " & $rc, 1)

let releaseRc = glowcap_host_release(host)
if releaseRc < 0:
  quit("glowcap_host_release failed: " & $releaseRc, 1)

echo "Host create/release: OK"
