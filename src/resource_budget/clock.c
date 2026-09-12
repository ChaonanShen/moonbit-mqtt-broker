#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <time.h>
int64_t mqtt_budget_monotonic_ms(void) {
  struct timespec value;
  if (clock_gettime(CLOCK_MONOTONIC, &value) != 0 || value.tv_sec < 0 ||
      value.tv_sec > (INT64_MAX - value.tv_nsec / 1000000) / 1000) return -1;
  return (int64_t)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}
