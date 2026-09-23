// RFC 6455 server accept key. Loaded only for an enabled WS/WSS listener.
#include <moonbit.h>
#include <dlfcn.h>
#include <stdint.h>
#include <string.h>

typedef int (*evp_digest_fn)(
  const void *, size_t, unsigned char *, unsigned int *, const void *, void *
);
typedef const void *(*evp_sha1_fn)(void);
static void *crypto_library = NULL;
static evp_digest_fn digest_fn = NULL;
static evp_sha1_fn sha1_fn = NULL;
static const char alphabet[] =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static const char guid[] = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

static int base64_value(unsigned char c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '+') return 62;
  if (c == '/') return 63;
  return -1;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_mqtt_websocket_crypto_initialize(void) {
  if (digest_fn != NULL) return 0;
  void *library = dlopen("libcrypto.so.3", RTLD_NOW | RTLD_LOCAL);
  if (library == NULL) return -1;
  evp_digest_fn digest = (evp_digest_fn)dlsym(library, "EVP_Digest");
  evp_sha1_fn sha1 = (evp_sha1_fn)dlsym(library, "EVP_sha1");
  if (digest == NULL || sha1 == NULL) {
    dlclose(library);
    return -2;
  }
  crypto_library = library;
  digest_fn = digest;
  sha1_fn = sha1;
  return 0;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_mqtt_websocket_accept(
  moonbit_bytes_t key, int32_t key_length, char *output, int32_t output_length
) {
  if (digest_fn == NULL || sha1_fn == NULL || crypto_library == NULL) return -1000;
  if (key_length != 24 || output_length != 28 || key[22] != '=' ||
      key[23] != '=') return -1;
  for (int i = 0; i < 22; ++i) {
    if (base64_value((unsigned char)key[i]) < 0) return -1;
  }
  // 16 decoded bytes leave four zero pad bits in the final sextet.
  if ((base64_value((unsigned char)key[21]) & 15) != 0) return -1;
  unsigned char input[60];
  memcpy(input, key, 24);
  memcpy(input + 24, guid, 36);
  unsigned char hash[20];
  unsigned int length = 0;
  if (digest_fn(input, sizeof(input), hash, &length, sha1_fn(), NULL) != 1 ||
      length != 20) return -2;
  for (int i = 0, o = 0; i < 20; i += 3, o += 4) {
    unsigned a = hash[i];
    unsigned b = i + 1 < 20 ? hash[i + 1] : 0;
    unsigned c = i + 2 < 20 ? hash[i + 2] : 0;
    output[o] = alphabet[a >> 2];
    output[o + 1] = alphabet[((a & 3) << 4) | (b >> 4)];
    output[o + 2] = i + 1 < 20 ?
      alphabet[((b & 15) << 2) | (c >> 6)] : '=';
    output[o + 3] = i + 2 < 20 ? alphabet[c & 63] : '=';
  }
  return 0;
}
