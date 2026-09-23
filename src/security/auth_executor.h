#ifndef MOONBIT_MQTT_AUTH_EXECUTOR_H
#define MOONBIT_MQTT_AUTH_EXECUTOR_H

#include <stddef.h>
#include <stdint.h>

typedef struct moonbit_mqtt_auth_executor moonbit_mqtt_auth_executor;

enum {
  MOONBIT_MQTT_AUTH_SUBMITTED = 0,
  MOONBIT_MQTT_AUTH_QUEUE_FULL = 1,
  MOONBIT_MQTT_AUTH_STOPPED = 2,
  MOONBIT_MQTT_AUTH_RETRY_LATER = 3,
  MOONBIT_MQTT_AUTH_INVALID = 4,
  MOONBIT_MQTT_AUTH_NO_MEMORY = 5
};

enum {
  MOONBIT_MQTT_AUTH_MATCHED = 0,
  MOONBIT_MQTT_AUTH_MISMATCHED = 1,
  MOONBIT_MQTT_AUTH_BACKEND_UNAVAILABLE = 2,
  MOONBIT_MQTT_AUTH_INTERNAL_FAILURE = 3,
  MOONBIT_MQTT_AUTH_CANCELLED_BEFORE_RUN = 4,
  MOONBIT_MQTT_AUTH_FINISHED_AFTER_CANCEL = 5
};

enum {
  MOONBIT_MQTT_AUTH_CANCELLED = 0,
  MOONBIT_MQTT_AUTH_CANCEL_MARKED_RUNNING = 1,
  MOONBIT_MQTT_AUTH_CANCEL_ALREADY_COMPLETED = 2,
  MOONBIT_MQTT_AUTH_CANCEL_UNKNOWN = 3,
  MOONBIT_MQTT_AUTH_CANCEL_RETRY_LATER = 4
};

typedef struct {
  int assigned;
  int queued;
  int running;
  int completed;
  int nonfree;
  int workers_alive;
} moonbit_mqtt_auth_stats;

moonbit_mqtt_auth_executor *moonbit_mqtt_auth_executor_create(
  int workers,
  int queue_limit
);
int moonbit_mqtt_auth_executor_submit(
  moonbit_mqtt_auth_executor *executor,
  int64_t task_id,
  const unsigned char *encoded,
  size_t encoded_length,
  const unsigned char *password,
  size_t password_length
);
int moonbit_mqtt_auth_executor_cancel(
  moonbit_mqtt_auth_executor *executor,
  int64_t task_id
);
int moonbit_mqtt_auth_executor_poll(
  moonbit_mqtt_auth_executor *executor,
  int64_t *task_id,
  int *result,
  int64_t *verify_ns
);
int moonbit_mqtt_auth_executor_completion(
  moonbit_mqtt_auth_executor *executor,
  int64_t task_id,
  int *result,
  int64_t *verify_ns
);
int moonbit_mqtt_auth_executor_reap(
  moonbit_mqtt_auth_executor *executor,
  int64_t task_id
);
int moonbit_mqtt_auth_executor_stop(moonbit_mqtt_auth_executor *executor);
int moonbit_mqtt_auth_executor_is_stopped(moonbit_mqtt_auth_executor *executor);
int moonbit_mqtt_auth_executor_stats(
  moonbit_mqtt_auth_executor *executor,
  moonbit_mqtt_auth_stats *stats
);
int moonbit_mqtt_auth_executor_destroy(moonbit_mqtt_auth_executor *executor);

#ifdef MOONBIT_MQTT_AUTH_EXECUTOR_TESTING
void moonbit_mqtt_auth_executor_test_fail_create_at(int index);
int moonbit_mqtt_auth_executor_test_hold(
  moonbit_mqtt_auth_executor *executor,
  int hold
);
int moonbit_mqtt_auth_executor_test_hold_running(
  moonbit_mqtt_auth_executor *executor,
  int hold
);
#endif

#endif
