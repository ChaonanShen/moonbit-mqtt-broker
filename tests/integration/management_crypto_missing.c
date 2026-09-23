#include <dlfcn.h>
#include <string.h>

// Only the broker's optional management crypto lookup is hidden.
void *dlopen(const char *filename, int flags) {
  static void *(*real_dlopen)(const char *, int) = NULL;
  if (real_dlopen == NULL) {
    real_dlopen = dlsym(RTLD_NEXT, "dlopen");
  }
  if (filename != NULL && strcmp(filename, "libcrypto.so.3") == 0) {
    return NULL;
  }
  return real_dlopen(filename, flags);
}
