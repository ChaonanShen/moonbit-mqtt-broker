#include "argon2_backend.h"

#include <moonbit.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

MOONBIT_FFI_EXPORT
int32_t moonbit_mqtt_verify_argon2id(
  moonbit_bytes_t encoded,
  int32_t encoded_length,
  moonbit_bytes_t password,
  int32_t password_length
) {
  if (encoded_length <= 0 || password_length < 0 ||
      memchr(encoded, '\0', (size_t)encoded_length) != NULL) {
    return -32; // ARGON2_DECODING_FAIL
  }
  char *encoded_utf8 = malloc((size_t)encoded_length + 1);
  if (encoded_utf8 == NULL) {
    return -1001;
  }
  memcpy(encoded_utf8, encoded, (size_t)encoded_length);
  encoded_utf8[encoded_length] = '\0';
  int result = moonbit_mqtt_argon2_verify(
    encoded_utf8,
    password,
    (size_t)password_length
  );
  memset(encoded_utf8, 0, (size_t)encoded_length);
  free(encoded_utf8);
  return result;
}
