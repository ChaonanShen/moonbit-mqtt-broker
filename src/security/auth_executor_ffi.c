#include "auth_executor.h"
#include "argon2_backend.h"

#include <moonbit.h>
#include <stdint.h>

static moonbit_mqtt_auth_executor *executor_from_handle(int64_t handle) {
  if (handle <= 0) {
    return NULL;
  }
  return (moonbit_mqtt_auth_executor *)(uintptr_t)handle;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_mqtt_auth_executor_initialize(void) {
  return moonbit_mqtt_argon2_initialize();
}

MOONBIT_FFI_EXPORT
int64_t moonbit_mqtt_auth_executor_create_ffi(
  int32_t workers,
  int32_t queue_limit
) {
  moonbit_mqtt_auth_executor *executor =
    moonbit_mqtt_auth_executor_create(workers, queue_limit);
  return (int64_t)(uintptr_t)executor;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_mqtt_auth_executor_submit_ffi(
  int64_t handle,
  int64_t task_id,
  moonbit_bytes_t encoded,
  int32_t encoded_length,
  moonbit_bytes_t password,
  int32_t password_length
) {
  if (encoded_length < 0 || password_length < 0) {
    return MOONBIT_MQTT_AUTH_INVALID;
  }
  return moonbit_mqtt_auth_executor_submit(
    executor_from_handle(handle),
    task_id,
    encoded,
    (size_t)encoded_length,
    password,
    (size_t)password_length
  );
}

MOONBIT_FFI_EXPORT
int32_t moonbit_mqtt_auth_executor_cancel_ffi(
  int64_t handle,
  int64_t task_id
) {
  return moonbit_mqtt_auth_executor_cancel(executor_from_handle(handle), task_id);
}

MOONBIT_FFI_EXPORT
int64_t moonbit_mqtt_auth_executor_poll_id_ffi(int64_t handle) {
  int64_t task_id = 0;
  int result = 0;
  int64_t verify_ns = 0;
  int status = moonbit_mqtt_auth_executor_poll(
    executor_from_handle(handle),
    &task_id,
    &result,
    &verify_ns
  );
  if (status == 1) {
    return task_id;
  }
  if (status == MOONBIT_MQTT_AUTH_RETRY_LATER) {
    return -1;
  }
  return status == 0 ? 0 : -2;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_mqtt_auth_executor_completion_result_ffi(
  int64_t handle,
  int64_t task_id
) {
  int result = 0;
  int64_t verify_ns = 0;
  int status = moonbit_mqtt_auth_executor_completion(
    executor_from_handle(handle),
    task_id,
    &result,
    &verify_ns
  );
  return status == MOONBIT_MQTT_AUTH_SUBMITTED ? result : 100 + status;
}

MOONBIT_FFI_EXPORT
int64_t moonbit_mqtt_auth_executor_completion_ns_ffi(
  int64_t handle,
  int64_t task_id
) {
  int result = 0;
  int64_t verify_ns = 0;
  int status = moonbit_mqtt_auth_executor_completion(
    executor_from_handle(handle),
    task_id,
    &result,
    &verify_ns
  );
  if (status == MOONBIT_MQTT_AUTH_SUBMITTED) {
    return verify_ns;
  }
  return status == MOONBIT_MQTT_AUTH_RETRY_LATER ? -1 : -2;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_mqtt_auth_executor_reap_ffi(
  int64_t handle,
  int64_t task_id
) {
  return moonbit_mqtt_auth_executor_reap(executor_from_handle(handle), task_id);
}

MOONBIT_FFI_EXPORT
int32_t moonbit_mqtt_auth_executor_stop_ffi(int64_t handle) {
  return moonbit_mqtt_auth_executor_stop(executor_from_handle(handle));
}

MOONBIT_FFI_EXPORT
int32_t moonbit_mqtt_auth_executor_is_stopped_ffi(int64_t handle) {
  return moonbit_mqtt_auth_executor_is_stopped(executor_from_handle(handle));
}

MOONBIT_FFI_EXPORT
int32_t moonbit_mqtt_auth_executor_destroy_ffi(int64_t handle) {
  return moonbit_mqtt_auth_executor_destroy(executor_from_handle(handle));
}
