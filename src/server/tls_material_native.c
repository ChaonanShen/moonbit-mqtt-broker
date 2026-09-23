// Private immutable TLS material snapshot for one broker startup generation.
#include <moonbit.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static int copy_file(int source, const char *destination) {
  int target = open(
    destination, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600
  );
  if (target < 0) return -1;
  char buffer[4096];
  size_t total = 0;
  int rc = 0;
  for (;;) {
    ssize_t got = read(source, buffer, sizeof(buffer));
    if (got < 0 && errno == EINTR) continue;
    if (got < 0) { rc = -1; break; }
    if (got == 0) break;
    total += (size_t)got;
    if (total > 1048576u) { rc = -1; break; }
    size_t offset = 0;
    while (offset < (size_t)got) {
      ssize_t wrote = write(target, buffer + offset, (size_t)got - offset);
      if (wrote < 0 && errno == EINTR) continue;
      if (wrote <= 0) { rc = -1; break; }
      offset += (size_t)wrote;
    }
    if (rc != 0) break;
  }
  if (rc == 0 && total == 0) rc = -1;
  if (close(target) != 0) rc = -1;
  if (rc != 0) unlink(destination);
  return rc;
}

static int open_source(
  moonbit_bytes_t input, int32_t length, int require_private
) {
  if (length < 1 || length > 4096 ||
      memchr(input, '\0', (size_t)length) != NULL) return -1;
  char path[4097];
  memcpy(path, input, (size_t)length);
  path[length] = '\0';
  int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
  if (fd < 0) return -1;
  struct stat st;
  if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) ||
      st.st_size < 1 || st.st_size > 1048576 ||
      (require_private &&
       ((st.st_uid != geteuid() && geteuid() != 0) ||
        (st.st_mode & 0077) != 0))) {
    close(fd);
    return -1;
  }
  return fd;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_mqtt_tls_material_capture(
  moonbit_bytes_t cert, int32_t cert_length,
  moonbit_bytes_t key, int32_t key_length,
  char *output, int32_t output_length
) {
  if (output_length < 128) return -1;
  int cert_fd = open_source(cert, cert_length, 0);
  if (cert_fd < 0) return -2;
  int key_fd = open_source(key, key_length, 1);
  if (key_fd < 0) { close(cert_fd); return -3; }
  char directory[] = "/tmp/moonbit-mqtt-tls-XXXXXX";
  if (mkdtemp(directory) == NULL) {
    close(cert_fd); close(key_fd); return -4;
  }
  char cert_path[128];
  char key_path[128];
  snprintf(cert_path, sizeof(cert_path), "%s/cert.pem", directory);
  snprintf(key_path, sizeof(key_path), "%s/key.pem", directory);
  int ok = copy_file(cert_fd, cert_path) == 0 &&
    copy_file(key_fd, key_path) == 0;
  close(cert_fd);
  close(key_fd);
  if (!ok) {
    unlink(cert_path);
    unlink(key_path);
    rmdir(directory);
    return -5;
  }
  size_t length = strlen(directory);
  if (length + 1 > (size_t)output_length) {
    unlink(cert_path);
    unlink(key_path);
    rmdir(directory);
    return -6;
  }
  memcpy(output, directory, length + 1);
  return 0;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_mqtt_tls_material_release(
  moonbit_bytes_t input, int32_t length
) {
  if (length < 24 || length > 127) return -1;
  char directory[128];
  memcpy(directory, input, (size_t)length);
  directory[length] = '\0';
  if (strncmp(directory, "/tmp/moonbit-mqtt-tls-", 21) != 0 ||
      strchr(directory + 21, '/') != NULL) return -1;
  char cert_path[160];
  char key_path[160];
  snprintf(cert_path, sizeof(cert_path), "%s/cert.pem", directory);
  snprintf(key_path, sizeof(key_path), "%s/key.pem", directory);
  int rc1 = unlink(cert_path);
  int rc2 = unlink(key_path);
  int rc3 = rmdir(directory);
  return rc1 == 0 && rc2 == 0 && rc3 == 0 ? 0 : -2;
}
