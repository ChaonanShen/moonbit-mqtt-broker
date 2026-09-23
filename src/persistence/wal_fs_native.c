#include <moonbit.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

/* Recovery calls this under broker.snapshot.lock, before opening listeners. */
MOONBIT_FFI_EXPORT
int32_t moonbit_mqtt_truncate_regular(
  moonbit_bytes_t input, int32_t input_length,
  int64_t expected_size, int64_t retained_size
) {
  if (input_length < 1 || input_length > 4096 ||
      memchr(input, '\0', (size_t)input_length) != NULL ||
      expected_size < 0 || retained_size < 0 || retained_size > expected_size) {
    return -EINVAL;
  }
  char path[4097];
  memcpy(path, input, (size_t)input_length);
  path[input_length] = '\0';
  int fd = open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
  if (fd < 0) return -errno;
  struct stat st;
  int error = 0;
  if (fstat(fd, &st) != 0) error = errno;
  else if (!S_ISREG(st.st_mode) || st.st_size != expected_size) error = EINVAL;
  else if (ftruncate(fd, (off_t)retained_size) != 0) error = errno;
  else if (fsync(fd) != 0) error = errno;
  if (close(fd) != 0 && error == 0) error = errno;
  return error == 0 ? 0 : -error;
}
