#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

static int trace_sync(int fd, const char *kind, int (*real_fn)(int)) {
  struct timespec before, after;
  clock_gettime(CLOCK_MONOTONIC, &before);
  int result = real_fn(fd);
  clock_gettime(CLOCK_MONOTONIC, &after);
  const char *trace = getenv("MQTT_FSYNC_TRACE");
  if (trace && *trace) {
    int out = open(trace, O_WRONLY | O_APPEND | O_CLOEXEC);
    if (out >= 0) {
      char link[64], target[256], line[512];
      snprintf(link, sizeof link, "/proc/self/fd/%d", fd);
      ssize_t len = readlink(link, target, sizeof target - 1);
      if (len < 0) len = 0;
      target[len] = '\0';
      long long ns = (after.tv_sec - before.tv_sec) * 1000000000LL +
                     after.tv_nsec - before.tv_nsec;
      int count = snprintf(line, sizeof line, "%lld.%09ld\t%s\t%d\t%lld\t%s\n",
                           (long long)before.tv_sec, before.tv_nsec, kind,
                           result, ns, target);
      if (count > 0 && count < (int)sizeof line)
        (void)syscall(SYS_write, out, line, (size_t)count);
      close(out);
    }
  }
  return result;
}

int fsync(int fd) {
  static int (*real_fn)(int);
  if (!real_fn) real_fn = dlsym(RTLD_NEXT, "fsync");
  return trace_sync(fd, "fsync", real_fn);
}

int fdatasync(int fd) {
  static int (*real_fn)(int);
  if (!real_fn) real_fn = dlsym(RTLD_NEXT, "fdatasync");
  return trace_sync(fd, "fdatasync", real_fn);
}
