#ifndef NIMOCPN_CRYPTO_OPENSSL_H
#define NIMOCPN_CRYPTO_OPENSSL_H
#include <stddef.h>
#include <stdint.h>
int nim_ed25519_public(const uint8_t seed[32], uint8_t public_key[32]);
int nim_ed25519_sign(const uint8_t seed[32], const uint8_t *message, size_t message_len, uint8_t signature[64]);
int nim_ed25519_verify(const uint8_t public_key[32], const uint8_t *message, size_t message_len, const uint8_t signature[64]);
int nim_sha256(const uint8_t *message, size_t message_len, uint8_t digest[32]);
#endif
