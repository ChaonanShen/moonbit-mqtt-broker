#include "argon2_backend.h"

#include <dlfcn.h>
#include <pthread.h>

typedef int (*argon2id_verify_fn)(
  const char *encoded,
  const void *password,
  size_t password_length
);

static argon2id_verify_fn moonbit_mqtt_argon2id_verify = NULL;
static void *moonbit_mqtt_argon2_library = NULL;
static pthread_once_t moonbit_mqtt_argon2_once = PTHREAD_ONCE_INIT;

static void initialize_argon2id_verify(void) {
  const char *names[] = { "libargon2.so.1", "libargon2.so" };
  for (size_t index = 0; index < sizeof(names) / sizeof(names[0]); index++) {
    void *library = dlopen(names[index], RTLD_NOW | RTLD_LOCAL);
    if (library == NULL) {
      continue;
    }
    argon2id_verify_fn verify =
      (argon2id_verify_fn)dlsym(library, "argon2id_verify");
    if (verify != NULL) {
      moonbit_mqtt_argon2_library = library;
      moonbit_mqtt_argon2id_verify = verify;
      return;
    }
    dlclose(library);
  }
}

int moonbit_mqtt_argon2_initialize(void) {
  if (pthread_once(&moonbit_mqtt_argon2_once, initialize_argon2id_verify) != 0) {
    return -1000;
  }
  return moonbit_mqtt_argon2id_verify == NULL ? -1000 : 0;
}

int moonbit_mqtt_argon2_verify(
  const char *encoded,
  const void *password,
  size_t password_length
) {
  if (moonbit_mqtt_argon2_initialize() != 0) {
    return -1000;
  }
  return moonbit_mqtt_argon2id_verify(encoded, password, password_length);
}
