// Vicinia — C dependencies (Vendor/, built by ./build-deps.sh).
// OpenSSL 3.5.9 libcrypto: big integers and constant-time modular
// exponentiation for SRP (also libsrtp's AES/HMAC backend).
// libsrtp 2.8.1: SRTP/SRTCP AES-256-ICM + HMAC-SHA1-80 with replay protection.
#include <openssl/bn.h>
#include <openssl/crypto.h>
#include <srtp2/srtp.h>
