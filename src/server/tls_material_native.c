// Private immutable TLS material snapshot. Multiple generations may coexist.
#define _POSIX_C_SOURCE 200809L
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

static int same_source(const struct stat *before, const struct stat *after) {
  return before->st_dev == after->st_dev &&
    before->st_ino == after->st_ino &&
    before->st_mode == after->st_mode &&
    before->st_uid == after->st_uid &&
    before->st_size == after->st_size &&
    before->st_mtim.tv_sec == after->st_mtim.tv_sec &&
    before->st_mtim.tv_nsec == after->st_mtim.tv_nsec &&
    before->st_ctim.tv_sec == after->st_ctim.tv_sec &&
    before->st_ctim.tv_nsec == after->st_ctim.tv_nsec;
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

// A successful copy must still name the same unchanged regular source.
static int source_stable(
  int original_fd, moonbit_bytes_t path, int32_t length,
  int require_private, const struct stat *before
) {
  struct stat after, current;
  if (fstat(original_fd, &after) != 0 || !same_source(before, &after)) {
    return 0;
  }
  int current_fd = open_source(path, length, require_private);
  if (current_fd < 0) return 0;
  int ok = fstat(current_fd, &current) == 0 &&
    same_source(before, &current);
  close(current_fd);
  return ok;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_mqtt_tls_material_preflight(
  moonbit_bytes_t cert, int32_t cert_length,
  moonbit_bytes_t key, int32_t key_length
) {
  int cert_fd = open_source(cert, cert_length, 0);
  if (cert_fd < 0) return -1;
  int key_fd = open_source(key, key_length, 1);
  close(cert_fd);
  if (key_fd < 0) return -2;
  close(key_fd);
  return 0;
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
  struct stat cert_before, key_before;
  if (fstat(cert_fd, &cert_before) != 0 ||
      fstat(key_fd, &key_before) != 0) {
    close(cert_fd); close(key_fd); return -3;
  }
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
  if (ok) {
    ok = source_stable(cert_fd, cert, cert_length, 0, &cert_before) &&
      source_stable(key_fd, key, key_length, 1, &key_before);
  }
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
  if (length < 24 || length > 639 ||
      memchr(input, '\0', (size_t)length) != NULL) return -1;
  char directory[640];
  memcpy(directory, input, (size_t)length);
  directory[length] = '\0';
  char *slash = strrchr(directory, '/');
  if (slash == NULL || slash == directory) return -1;
  const char *name = slash + 1;
  if (strlen(name) != 23 ||
      strncmp(name, "moonbit-mqtt-tls-", 17) != 0 ||
      strchr(name, '/') != NULL) return -1;
  *slash = '\0';
  int root = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (root < 0) return -1;
  struct stat root_status;
  if (fstat(root, &root_status) != 0 ||
      !S_ISDIR(root_status.st_mode) ||
      (strcmp(directory, "/tmp") != 0 &&
       (root_status.st_uid != geteuid() ||
        (root_status.st_mode & 0077) != 0))) {
    close(root);
    return -1;
  }
  int child = openat(root, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (child < 0) {
    close(root);
    return -1;
  }
  struct stat child_status;
  if (fstat(child, &child_status) != 0 ||
      !S_ISDIR(child_status.st_mode) ||
      child_status.st_uid != geteuid() ||
      (child_status.st_mode & 0077) != 0) {
    close(child); close(root);
    return -1;
  }
  int cert = unlinkat(child, "cert.pem", 0);
  int key = unlinkat(child, "key.pem", 0);
  close(child);
  int removed = unlinkat(root, name, AT_REMOVEDIR);
  close(root);
  return cert == 0 && key == 0 && removed == 0 ? 0 : -2;
}
