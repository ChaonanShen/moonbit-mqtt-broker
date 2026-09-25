#include <moonbit.h>
#include <errno.h>
#include <stdint.h>
#include <sys/random.h>

MOONBIT_FFI_EXPORT
int32_t moonbit_mqtt5_random_16(char *output, int32_t length) {
  if (output == NULL || length != 16) return -1;
  int32_t offset = 0;
  for (int attempts = 0; attempts < 4 && offset < 16; ++attempts) {
    ssize_t count = getrandom(output + offset, (size_t)(16 - offset), GRND_NONBLOCK);
    if (count < 0) {
      if (errno == EINTR) continue;
      return -2;
    }
    if (count == 0) return -3;
    offset += (int32_t)count;
  }
  return offset == 16 ? 0 : -4;
}
