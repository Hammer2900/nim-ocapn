import std/os

{.compile: "crypto_openssl.c".}
const cryptoSourceDir = currentSourcePath().parentDir
{.passC: "-I" & cryptoSourceDir.}
{.passL: "-lcrypto".}

type CryptoError* = object of CatchableError

proc nim_ed25519_public(seed: ptr uint8; publicKey: ptr uint8): cint {.importc, header: "crypto_openssl.h".}
proc nim_ed25519_sign(seed, message: ptr uint8; messageLen: csize_t; signature: ptr uint8): cint {.importc, header: "crypto_openssl.h".}
proc nim_ed25519_verify(publicKey, message: ptr uint8; messageLen: csize_t; signature: ptr uint8): cint {.importc, header: "crypto_openssl.h".}
proc nim_sha256(message: ptr uint8; messageLen: csize_t; digest: ptr uint8): cint {.importc, header: "crypto_openssl.h".}

proc publicKey*(seed: string): string =
  if seed.len != 32: raise newException(CryptoError, "Ed25519 seed must be 32 bytes")
  result = newString(32)
  if nim_ed25519_public(cast[ptr uint8](seed.cstring), cast[ptr uint8](result.cstring)) != 0:
    raise newException(CryptoError, "Ed25519 public key generation failed")

proc sign*(seed, message: string): string =
  if seed.len != 32: raise newException(CryptoError, "Ed25519 seed must be 32 bytes")
  result = newString(64)
  if nim_ed25519_sign(cast[ptr uint8](seed.cstring), cast[ptr uint8](message.cstring),
      message.len.csize_t, cast[ptr uint8](result.cstring)) != 0:
    raise newException(CryptoError, "Ed25519 signing failed")

proc verify*(publicKey, message, signature: string): bool =
  if publicKey.len != 32 or signature.len != 64: return false
  nim_ed25519_verify(cast[ptr uint8](publicKey.cstring), cast[ptr uint8](message.cstring),
    message.len.csize_t, cast[ptr uint8](signature.cstring)) == 0

proc sha256*(message: string): string =
  result = newString(32)
  if nim_sha256(cast[ptr uint8](message.cstring), message.len.csize_t,
      cast[ptr uint8](result.cstring)) != 0:
    raise newException(CryptoError, "SHA-256 failed")
