#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

int fsync(int fd) {
  static int (*real_fsync)(int) = NULL;
  if (!real_fsync) real_fsync = dlsym(RTLD_NEXT, "fsync");
  const char *arm = getenv("MQTT_WAL_FSYNC_ARM");
  const char *marker = getenv("MQTT_WAL_FSYNC_MARKER");
  const char *release = getenv("MQTT_WAL_FSYNC_RELEASE");
  if (!arm || !marker || !release || access(arm, F_OK) != 0 ||
      access(marker, F_OK) == 0) return real_fsync(fd);
  char link_path[64], target[4096];
  snprintf(link_path, sizeof link_path, "/proc/self/fd/%d", fd);
  ssize_t length = readlink(link_path, target, sizeof target - 1);
  if (length < 0) return real_fsync(fd);
  target[length] = '\0';
  if (!strstr(target, "/wal-") || !strstr(target, ".log"))
    return real_fsync(fd);
  struct stat st;
  if (fstat(fd, &st) != 0 || st.st_size <= 40) return real_fsync(fd);
  int marker_fd = open(marker, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600);
  if (marker_fd < 0) return real_fsync(fd);
  (void)write(marker_fd, "held\n", 5);
  close(marker_fd);
  struct timespec delay = { .tv_sec = 0, .tv_nsec = 1000000L };
  for (int i = 0; i < 10000; i++) {
    if (access(release, F_OK) == 0) return real_fsync(fd);
    nanosleep(&delay, NULL);
  }
  errno = EIO;
  return -1;
}
