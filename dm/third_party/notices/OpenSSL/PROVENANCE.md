# OpenSSL

The Apple game host statically links libcrypto for strict verification of explicitly configured private service certificates. OpenSSL 4.1.0 is licensed under Apache-2.0; the unchanged [license text](LICENSE.txt) accompanies Studio and exported game applications. Source: https://github.com/openssl/openssl/releases/tag/openssl-4.1.0. The download SHA-256 is pinned in `dm/tools/apple_crypto.py`. No OpenSSL source or compiled library is vendored here.
