#include <dlfcn.h>
#include <moonbit.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef int (*argon2id_verify_fn)(
  const char *encoded,
  const void *password,
  size_t password_length
);

int32_t moonbit_utf8_len_from_utf16(
  moonbit_string_t src,
  int32_t src_offset,
  int32_t src_length
);

int32_t moonbit_utf8_encode_from_utf16(
  moonbit_string_t src,
  int32_t src_offset,
  int32_t src_length,
  moonbit_bytes_t dst,
  int32_t dst_offset
);

static argon2id_verify_fn moonbit_mqtt_argon2id_verify = NULL;
static int moonbit_mqtt_argon2_loaded = 0;

static argon2id_verify_fn load_argon2id_verify(void) {
  if (!moonbit_mqtt_argon2_loaded) {
    moonbit_mqtt_argon2_loaded = 1;
    const char *names[] = { "libargon2.so.1", "libargon2.so" };
    for (size_t index = 0; index < sizeof(names) / sizeof(names[0]); index++) {
      void *library = dlopen(names[index], RTLD_NOW | RTLD_LOCAL);
      if (library != NULL) {
        moonbit_mqtt_argon2id_verify =
          (argon2id_verify_fn)dlsym(library, "argon2id_verify");
        if (moonbit_mqtt_argon2id_verify != NULL) {
          break;
        }
      }
    }
  }
  return moonbit_mqtt_argon2id_verify;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_mqtt_verify_argon2id(
  moonbit_string_t encoded,
  int32_t encoded_length,
  moonbit_bytes_t password,
  int32_t password_length
) {
  argon2id_verify_fn verify = load_argon2id_verify();
  if (verify == NULL) {
    return -1000;
  }
  int32_t utf8_length = moonbit_utf8_len_from_utf16(
    encoded,
    0,
    encoded_length
  );
  char *encoded_utf8 = malloc((size_t)utf8_length + 1);
  if (encoded_utf8 == NULL) {
    return -1001;
  }
  moonbit_utf8_encode_from_utf16(
    encoded,
    0,
    encoded_length,
    (moonbit_bytes_t)encoded_utf8,
    0
  );
  encoded_utf8[utf8_length] = '\0';
  int result = verify(encoded_utf8, password, (size_t)password_length);
  memset(encoded_utf8, 0, (size_t)utf8_length);
  free(encoded_utf8);
  return result;
}
