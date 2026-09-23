#include <moonbit.h>
#include <dirent.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern int32_t moonbit_mqtt_management_crypto_initialize(void);
extern int32_t moonbit_mqtt_management_hash_token(
    moonbit_bytes_t, int32_t, char *, int32_t);
extern int32_t moonbit_mqtt_management_read_token_file(
    moonbit_bytes_t, int32_t, char *, int32_t);

static int fd_count(void) {
  DIR *dir = opendir("/proc/self/fd");
  if (dir == NULL) return -1;
  int result = 0;
  struct dirent *item;
  while ((item = readdir(dir)) != NULL) {
    if (strcmp(item->d_name, ".") != 0 &&
        strcmp(item->d_name, "..") != 0) result++;
  }
  closedir(dir);
  return result;
}

static int check_read(const char *path, int expected) {
  char out[16385] = {0};
  int result = moonbit_mqtt_management_read_token_file(
      (moonbit_bytes_t)path, (int32_t)strlen(path), out, (int32_t)sizeof(out));
  if (result != expected) {
    fprintf(stderr, "read code mismatch: expected=%d got=%d\n", expected, result);
    return 1;
  }
  return 0;
}

int main(int argc, char **argv) {
  if (argc != 2) return 2;
  const char *dir = argv[1];
  const char *names[] = {
    "valid", "max", "too-large", "oversize", "symlink", "fifo", "directory",
    "permissive", "foreign", "missing"
  };
  const int expected[] = {29, 16384, 16385, -28, -21, -25, -25, -27, -26, -22};
  char path[4096];
  for (unsigned int i = 0; i < sizeof(names)/sizeof(names[0]); ++i) {
    int length = snprintf(path, sizeof(path), "%s/%s", dir, names[i]);
    if (length < 0 || length >= (int)sizeof(path)) return 3;
    if (check_read(path, expected[i])) return 4;
  }
  if (moonbit_mqtt_management_read_token_file(
        (moonbit_bytes_t)"a\0b", 3, path, (int32_t)sizeof(path)) != -20) return 5;
  const int before = fd_count();
  if (before < 0) return 6;
  for (int i = 0; i < 100; ++i) {
    int length = snprintf(path, sizeof(path), "%s/fifo", dir);
    if (length < 0 || length >= (int)sizeof(path)) return 7;
    if (check_read(path, -25)) return 8;
    length = snprintf(path, sizeof(path), "%s/oversize", dir);
    if (length < 0 || length >= (int)sizeof(path)) return 9;
    if (check_read(path, -28)) return 10;
  }
  if (fd_count() != before) return 11;
  if (moonbit_mqtt_management_crypto_initialize() != 0) return 12;
  unsigned char digest[32];
  if (moonbit_mqtt_management_hash_token(
        (moonbit_bytes_t)"abc", 3, (char *)digest, 32) != 0) return 13;
  const unsigned char prefix[] = {0xba, 0x78, 0x16, 0xbf};
  if (memcmp(digest, prefix, sizeof(prefix)) != 0) return 14;
  puts("management native file/ABI/fd cases passed");
  return 0;
}
