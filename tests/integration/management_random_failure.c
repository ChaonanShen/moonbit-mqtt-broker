#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#ifndef FAILURE_ERRNO
#error FAILURE_ERRNO must be EAGAIN or ENOSYS
#endif

ssize_t getrandom(void *buf, size_t len, unsigned int flags) {
  (void)buf;
  (void)len;
  (void)flags;
  errno = FAILURE_ERRNO;
  return -1;
}

extern int32_t moonbit_mqtt_management_secure_random(char *output, int32_t length);

int main(void) {
  char output[32] = {0};
#if FAILURE_ERRNO == EAGAIN
  return moonbit_mqtt_management_secure_random(output, 32) == -10 ? 0 : 1;
#elif FAILURE_ERRNO == ENOSYS
  return moonbit_mqtt_management_secure_random(output, 32) == -11 ? 0 : 1;
#else
  return 2;
#endif
}
