// Test-only fault injection: model a machine without the optional runtime.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>

void *dlopen(const char *name, int flags) {
  if (name != NULL &&
      (strcmp(name, "libargon2.so.1") == 0 || strcmp(name, "libargon2.so") == 0)) {
    return NULL;
  }
  void *(*original)(const char *, int) = dlsym(RTLD_NEXT, "dlopen");
  return original(name, flags);
}
