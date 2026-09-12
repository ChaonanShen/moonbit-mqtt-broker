#define _POSIX_C_SOURCE 200809L
#define MOONBIT_MQTT_AUTH_EXECUTOR_TESTING 1
#include "../../src/security/auth_executor.h"

#include <assert.h>
#include <stdio.h>
#include <time.h>

static const unsigned char encoded[] =
  "$argon2id$v=19$m=4096,t=2,p=1$MDEyMzQ1Njc4OWFiY2RlZg$"
  "L6c7kPn0Q0+pwt7HHxzhhB+QGg1khTPaRz9eiHBu/eM";

static int submit_retry(
  moonbit_mqtt_auth_executor *executor,
  int64_t id,
  const char *password,
  size_t password_length
) {
  for (int attempt = 0; attempt < 100000; attempt++) {
    int status = moonbit_mqtt_auth_executor_submit(
      executor,
      id,
      encoded,
      sizeof(encoded) - 1,
      (const unsigned char *)password,
      password_length
    );
    if (status != MOONBIT_MQTT_AUTH_RETRY_LATER) {
      return status;
    }
  }
  assert(!"submit retry timed out");
  return -1;
}

static int cancel_retry(moonbit_mqtt_auth_executor *executor, int64_t id) {
  for (int attempt = 0; attempt < 100000; attempt++) {
    int status = moonbit_mqtt_auth_executor_cancel(executor, id);
    if (status != MOONBIT_MQTT_AUTH_CANCEL_RETRY_LATER) {
      return status;
    }
  }
  assert(!"cancel retry timed out");
  return -1;
}

static int reap_retry(moonbit_mqtt_auth_executor *executor, int64_t id) {
  for (int attempt = 0; attempt < 100000; attempt++) {
    int status = moonbit_mqtt_auth_executor_reap(executor, id);
    if (status != MOONBIT_MQTT_AUTH_RETRY_LATER) {
      return status;
    }
  }
  assert(!"reap retry timed out");
  return -1;
}

static int stats_retry(
  moonbit_mqtt_auth_executor *executor,
  moonbit_mqtt_auth_stats *stats
) {
  for (int attempt = 0; attempt < 100000; attempt++) {
    int status = moonbit_mqtt_auth_executor_stats(executor, stats);
    if (status != MOONBIT_MQTT_AUTH_RETRY_LATER) {
      return status;
    }
  }
  assert(!"stats retry timed out");
  return -1;
}

static int stop_retry(moonbit_mqtt_auth_executor *executor) {
  for (int attempt = 0; attempt < 100000; attempt++) {
    int status = moonbit_mqtt_auth_executor_stop(executor);
    if (status != MOONBIT_MQTT_AUTH_RETRY_LATER) {
      return status;
    }
  }
  assert(!"stop retry timed out");
  return -1;
}

static int wait_result(
  moonbit_mqtt_auth_executor *executor,
  int64_t expected_id,
  int expected_result
) {
  struct timespec pause = { .tv_sec = 0, .tv_nsec = 1000000 };
  for (int attempt = 0; attempt < 10000; attempt++) {
    int64_t id = 0;
    int result = -1;
    int64_t verify_ns = -1;
    int status = moonbit_mqtt_auth_executor_poll(executor, &id, &result, &verify_ns);
    if (status == MOONBIT_MQTT_AUTH_RETRY_LATER) {
      continue;
    }
    if (status == 1) {
      assert(id == expected_id);
      assert(result == expected_result);
      assert(verify_ns >= 0);
      return reap_retry(executor, id);
    }
    nanosleep(&pause, NULL);
  }
  assert(!"authentication result timed out");
  return -1;
}

int main(void) {
  moonbit_mqtt_auth_executor *executor =
    moonbit_mqtt_auth_executor_create(1, 1);
  assert(executor != NULL);
  assert(moonbit_mqtt_auth_executor_test_hold(executor, 1) == 0);
  assert(submit_retry(executor, 1, "correct horse", 13) ==
    MOONBIT_MQTT_AUTH_SUBMITTED);
  assert(submit_retry(executor, 2, "wrong", 5) ==
    MOONBIT_MQTT_AUTH_SUBMITTED);
  assert(submit_retry(executor, 3, "wrong", 5) ==
    MOONBIT_MQTT_AUTH_QUEUE_FULL);

  moonbit_mqtt_auth_stats stats;
  assert(stats_retry(executor, &stats) == 0);
  assert(stats.assigned == 1 && stats.queued == 1 && stats.nonfree == 2);
  assert(cancel_retry(executor, 2) == MOONBIT_MQTT_AUTH_CANCELLED);
  assert(wait_result(executor, 2, MOONBIT_MQTT_AUTH_CANCELLED_BEFORE_RUN) == 0);

  assert(moonbit_mqtt_auth_executor_test_hold(executor, 0) == 0);
  assert(wait_result(executor, 1, MOONBIT_MQTT_AUTH_MATCHED) == 0);
  assert(submit_retry(executor, 4, "wrong", 5) ==
    MOONBIT_MQTT_AUTH_SUBMITTED);
  assert(wait_result(executor, 4, MOONBIT_MQTT_AUTH_MISMATCHED) == 0);

  assert(moonbit_mqtt_auth_executor_test_hold_running(executor, 1) == 0);
  assert(submit_retry(executor, 5, "correct horse", 13) ==
    MOONBIT_MQTT_AUTH_SUBMITTED);
  for (int attempt = 0; attempt < 100000; attempt++) {
    assert(stats_retry(executor, &stats) == 0);
    if (stats.running == 1) {
      break;
    }
    if (attempt == 99999) {
      assert(!"running task did not start");
    }
  }
  assert(cancel_retry(executor, 5) == MOONBIT_MQTT_AUTH_CANCEL_MARKED_RUNNING);
  assert(stats_retry(executor, &stats) == 0);
  assert(stats.running == 1);
  assert(moonbit_mqtt_auth_executor_test_hold_running(executor, 0) == 0);
  assert(wait_result(executor, 5, MOONBIT_MQTT_AUTH_FINISHED_AFTER_CANCEL) == 0);

  assert(stop_retry(executor) == 0);
  for (int attempt = 0; attempt < 100000; attempt++) {
    int stopped = moonbit_mqtt_auth_executor_is_stopped(executor);
    if (stopped == 1) {
      break;
    }
    if (attempt == 99999) {
      assert(!"executor stop timed out");
    }
  }
  assert(moonbit_mqtt_auth_executor_destroy(executor) == 0);
  puts("AUTH EXECUTOR native harness passed: W/Q, queue full, queued/running cancel, match, mismatch, stop");
  return 0;
}
