import std/[monotimes, os, posix, sysrand, times]
import ./crypto

type
  IdentityError* = object of CatchableError
  TransportAuthEvidence* = object
    ## Evidence is supplied by a concrete netlayer, not inferred from an
    ## address or from the CapTP hello. Empty/default evidence is untrusted.
    peerIdentity*: string
    transportIdentity*: string
    proofType*: string
    authenticated*: bool
    channelIntegrity*: bool
    channelConfidential*: bool
  TransportEvidenceVerifier* = proc(evidence: TransportAuthEvidence;
                                    captpPublicKey: string): bool {.closure.}
  PeerVerificationMode* = enum
    pvmTestingOnly
    pvmExactIdentity
    pvmAuthenticatedNetlayer
  PeerVerificationPolicy* = object
    mode*: PeerVerificationMode
    expectedPublicKey*: string
    transportVerifier*: TransportEvidenceVerifier
  NodeIdentity* = ref object
    publicKey*: string
    path*: string
    secret: string

const
  IdentityMagic = "NIMOCAPN-ID"
  IdentityVersion = 1
  IdentityChecksumSize = 32
  IdentitySeedSize = 32

const testingOnlyPeerPolicy* = PeerVerificationPolicy(mode: pvmTestingOnly)

proc exactPeerPolicy*(publicKey: string): PeerVerificationPolicy =
  if publicKey.len != 32:
    raise newException(IdentityError, "expected Ed25519 public key must be 32 bytes")
  PeerVerificationPolicy(mode: pvmExactIdentity, expectedPublicKey: publicKey)

proc authenticatedNetlayerPolicy*(verifier: TransportEvidenceVerifier = nil): PeerVerificationPolicy =
  PeerVerificationPolicy(mode: pvmAuthenticatedNetlayer, transportVerifier: verifier)

proc validatePolicy*(policy: PeerVerificationPolicy) =
  if policy.mode == pvmExactIdentity and policy.expectedPublicKey.len != 32:
    raise newException(IdentityError, "exact peer policy requires a 32-byte public key")
  if policy.mode != pvmExactIdentity and policy.expectedPublicKey.len != 0:
    raise newException(IdentityError, "unexpected key in non-exact peer policy")

proc newEphemeralIdentity*(seed: string): NodeIdentity =
  if seed.len != IdentitySeedSize:
    raise newException(IdentityError, "Ed25519 identity seed must be 32 bytes")
  NodeIdentity(publicKey: crypto.publicKey(seed), secret: seed)

proc sessionSeed*(identity: NodeIdentity): string =
  ## Internal bridge used by Session/Node constructors. It returns the
  ## already-loaded private seed; callers must not log or serialize it.
  if identity.isNil or identity.secret.len != IdentitySeedSize:
    raise newException(IdentityError, "identity is unavailable")
  identity.secret

proc encodedIdentity(seed: string): string =
  result = IdentityMagic
  result.add(char(IdentityVersion))
  result.add(seed)
  result.add(crypto.sha256(result))

proc decodeIdentity(path, input: string): NodeIdentity =
  let expectedLength = IdentityMagic.len + 1 + IdentitySeedSize + IdentityChecksumSize
  if input.len != expectedLength:
    raise newException(IdentityError, "identity file has invalid length")
  if input[0 ..< IdentityMagic.len] != IdentityMagic:
    raise newException(IdentityError, "identity file has invalid magic")
  if ord(input[IdentityMagic.len]) != IdentityVersion:
    raise newException(IdentityError, "unsupported identity file version")
  let seedStart = IdentityMagic.len + 1
  let seed = input[seedStart ..< seedStart + IdentitySeedSize]
  let checksum = input[seedStart + IdentitySeedSize .. ^1]
  let body = input[0 ..< seedStart + IdentitySeedSize]
  if crypto.sha256(body) != checksum:
    raise newException(IdentityError, "identity file checksum mismatch")
  result = newEphemeralIdentity(seed)
  result.path = path

proc loadIdentity*(path: string): NodeIdentity =
  if path.len == 0:
    raise newException(IdentityError, "identity path is empty")
  if not fileExists(path):
    raise newException(IdentityError, "identity file does not exist")
  try:
    result = decodeIdentity(path, readFile(path))
  except IdentityError:
    raise
  except CatchableError as error:
    raise newException(IdentityError, "cannot read identity file: " & error.msg)

proc identityLock(path: string): string = path & ".lock"

proc acquireIdentityLock(path: string): cint =
  when defined(posix):
    result = posix.open(path.cstring, O_WRONLY or O_CREAT or O_EXCL, Mode(0o600))
    if result < 0:
      raise newException(IdentityError, "identity path is already locked")
  else:
    if fileExists(path):
      raise newException(IdentityError, "identity path is already locked")
    writeFile(path, "lock")
    result = 0

proc releaseIdentityLock(path: string; descriptor: cint) =
  when defined(posix):
    if descriptor >= 0:
      discard posix.close(descriptor)
  if fileExists(path):
    removeFile(path)

proc writeIdentity*(path: string; identity: NodeIdentity;
                   replaceExisting = false) =
  if path.len == 0 or identity.isNil or identity.secret.len != IdentitySeedSize:
    raise newException(IdentityError, "invalid identity write request")
  if fileExists(path) and not replaceExisting:
    raise newException(IdentityError, "identity file already exists")
  let lockPath = identityLock(path)
  var lockDescriptor: cint = -1
  var temporary = ""
  try:
    lockDescriptor = acquireIdentityLock(lockPath)
    if fileExists(path) and not replaceExisting:
      raise newException(IdentityError, "identity file already exists")
    temporary = path & ".tmp." & $getCurrentProcessId() & "." & $getTime().toUnix()
    writeFile(temporary, encodedIdentity(identity.secret))
    setFilePermissions(temporary, {fpUserRead, fpUserWrite})
    when defined(posix):
      let fd = posix.open(temporary.cstring, O_WRONLY, Mode(0o600))
      if fd >= 0:
        discard fsync(fd)
        discard posix.close(fd)
    moveFile(temporary, path)
    setFilePermissions(path, {fpUserRead, fpUserWrite})
  except IdentityError:
    if temporary.len > 0 and fileExists(temporary): removeFile(temporary)
    raise
  except CatchableError as error:
    if temporary.len > 0 and fileExists(temporary): removeFile(temporary)
    raise newException(IdentityError, "cannot write identity file: " & error.msg)
  finally:
    releaseIdentityLock(lockPath, lockDescriptor)

proc createIdentity*(path: string; replaceExisting = false): NodeIdentity =
  let randomBytes = urandom(IdentitySeedSize)
  var seed = newString(randomBytes.len)
  for index, value in randomBytes:
    seed[index] = char(value)
  result = newEphemeralIdentity(seed)
  result.path = path
  writeIdentity(path, result, replaceExisting)

proc loadOrCreateIdentity*(path: string): NodeIdentity =
  if fileExists(path): return loadIdentity(path)
  try:
    return createIdentity(path)
  except IdentityError:
    let lockPath = identityLock(path)
    if not fileExists(lockPath): raise
    let deadline = getMonoTime() + initDuration(seconds = 2)
    while getMonoTime() < deadline:
      if fileExists(path): return loadIdentity(path)
      sleep(10)
    raise newException(IdentityError, "identity creation remained locked")

