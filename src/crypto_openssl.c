#include "crypto_openssl.h"
#include <openssl/evp.h>
#include <openssl/sha.h>

static EVP_PKEY *private_key(const uint8_t seed[32]) {
    return EVP_PKEY_new_raw_private_key(EVP_PKEY_ED25519, NULL, seed, 32);
}

int nim_ed25519_public(const uint8_t seed[32], uint8_t public_key[32]) {
    EVP_PKEY *key = private_key(seed); size_t len = 32; int ok = 0;
    if (key) ok = EVP_PKEY_get_raw_public_key(key, public_key, &len) == 1 && len == 32;
    EVP_PKEY_free(key); return ok ? 0 : -1;
}

int nim_ed25519_sign(const uint8_t seed[32], const uint8_t *message, size_t message_len, uint8_t signature[64]) {
    EVP_PKEY *key = private_key(seed); EVP_MD_CTX *ctx = EVP_MD_CTX_new(); size_t len = 64; int ok = 0;
    if (key && ctx && EVP_DigestSignInit(ctx, NULL, NULL, NULL, key) == 1 &&
        EVP_DigestSign(ctx, signature, &len, message, message_len) == 1 && len == 64) ok = 1;
    EVP_MD_CTX_free(ctx); EVP_PKEY_free(key); return ok ? 0 : -1;
}

int nim_ed25519_verify(const uint8_t public_key[32], const uint8_t *message, size_t message_len, const uint8_t signature[64]) {
    EVP_PKEY *key = EVP_PKEY_new_raw_public_key(EVP_PKEY_ED25519, NULL, public_key, 32);
    EVP_MD_CTX *ctx = EVP_MD_CTX_new(); int ok = 0;
    if (key && ctx && EVP_DigestVerifyInit(ctx, NULL, NULL, NULL, key) == 1)
        ok = EVP_DigestVerify(ctx, signature, 64, message, message_len) == 1;
    EVP_MD_CTX_free(ctx); EVP_PKEY_free(key); return ok ? 0 : -1;
}

int nim_sha256(const uint8_t *message, size_t message_len, uint8_t digest[32]) {
    return SHA256(message, message_len, digest) != NULL ? 0 : -1;
}
