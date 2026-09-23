#define _POSIX_C_SOURCE 200809L
#include "auth_executor.h"
#include "argon2_backend.h"

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef MOONBIT_MQTT_AUTH_EXECUTOR_TESTING
#include <sched.h>
#endif

#define AUTH_EXECUTOR_MAX_WORKERS 64
#define AUTH_EXECUTOR_MAX_RECORDS 4096

#ifdef MOONBIT_MQTT_AUTH_EXECUTOR_TESTING
static int test_fail_create_at = -1;

void moonbit_mqtt_auth_executor_test_fail_create_at(int index) {
  test_fail_create_at = index;
}
#endif

typedef enum {
  AUTH_TASK_FREE = 0,
  AUTH_TASK_ASSIGNED = 1,
  AUTH_TASK_QUEUED = 2,
  AUTH_TASK_RUNNING = 3,
  AUTH_TASK_CLEANING = 4,
  AUTH_TASK_COMPLETED = 5
} auth_task_state;

typedef struct {
  atomic_int state;
  atomic_int cancel_requested;
  int64_t id;
  char *encoded;
  unsigned char *password;
  size_t password_length;
  int result;
  int64_t verify_ns;
} auth_task;

struct moonbit_mqtt_auth_executor {
  pthread_mutex_t lock;
  pthread_cond_t wake;
  pthread_t *threads;
  auth_task *tasks;
  int worker_count;
  int queue_limit;
  int capacity;
  int accepting;
  int stopping;
  int active;
  int queued;
  int running;
  int workers_alive;
#ifdef MOONBIT_MQTT_AUTH_EXECUTOR_TESTING
  int test_hold;
  atomic_int test_running_hold;
#endif
};

static void secure_clear(void *pointer, size_t length) {
  volatile unsigned char *bytes = pointer;
  while (length > 0) {
    *bytes++ = 0;
    length--;
  }
}

static void release_inputs(char *encoded, unsigned char *password, size_t password_length) {
  if (password != NULL) {
    secure_clear(password, password_length);
    free(password);
  }
  if (encoded != NULL) {
    secure_clear(encoded, strlen(encoded));
    free(encoded);
  }
}

static int64_t monotonic_ns(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
    return 0;
  }
  return (int64_t)now.tv_sec * 1000000000LL + (int64_t)now.tv_nsec;
}

static auth_task *find_task(moonbit_mqtt_auth_executor *executor, int64_t id) {
  for (int index = 0; index < executor->capacity; index++) {
    auth_task *task = &executor->tasks[index];
    if (atomic_load_explicit(&task->state, memory_order_acquire) != AUTH_TASK_FREE &&
        task->id == id) {
      return task;
    }
  }
  return NULL;
}

static auth_task *find_state(moonbit_mqtt_auth_executor *executor, int state) {
  for (int index = 0; index < executor->capacity; index++) {
    auth_task *task = &executor->tasks[index];
    if (atomic_load_explicit(&task->state, memory_order_acquire) == state) {
      return task;
    }
  }
  return NULL;
}

static void promote_queued(moonbit_mqtt_auth_executor *executor) {
  if (executor->stopping || executor->active >= executor->worker_count) {
    return;
  }
  auth_task *task = find_state(executor, AUTH_TASK_QUEUED);
  if (task != NULL) {
    executor->queued--;
    executor->active++;
    atomic_store_explicit(&task->state, AUTH_TASK_ASSIGNED, memory_order_release);
    pthread_cond_signal(&executor->wake);
  }
}

static void complete_cleaning_task(auth_task *task) {
  char *encoded = task->encoded;
  unsigned char *password = task->password;
  size_t password_length = task->password_length;
  task->encoded = NULL;
  task->password = NULL;
  task->password_length = 0;
  release_inputs(encoded, password, password_length);
  task->result = MOONBIT_MQTT_AUTH_CANCELLED_BEFORE_RUN;
  task->verify_ns = 0;
  atomic_store_explicit(&task->state, AUTH_TASK_COMPLETED, memory_order_release);
}

static void *auth_worker(void *context) {
  moonbit_mqtt_auth_executor *executor = context;
  for (;;) {
    pthread_mutex_lock(&executor->lock);
#ifdef MOONBIT_MQTT_AUTH_EXECUTOR_TESTING
    while (executor->test_hold && !executor->stopping) {
      pthread_cond_wait(&executor->wake, &executor->lock);
    }
#endif
    auth_task *task = NULL;
    if (executor->stopping) {
      task = find_state(executor, AUTH_TASK_ASSIGNED);
      if (task != NULL) {
        executor->active--;
      } else {
        task = find_state(executor, AUTH_TASK_QUEUED);
        if (task != NULL) {
          executor->queued--;
        }
      }
      if (task != NULL) {
        atomic_store_explicit(&task->state, AUTH_TASK_CLEANING, memory_order_release);
        pthread_mutex_unlock(&executor->lock);
        complete_cleaning_task(task);
        continue;
      }
      if (executor->running == 0) {
        executor->workers_alive--;
        pthread_mutex_unlock(&executor->lock);
        return NULL;
      }
    } else {
      task = find_state(executor, AUTH_TASK_ASSIGNED);
    }
    if (task == NULL) {
      pthread_cond_wait(&executor->wake, &executor->lock);
      pthread_mutex_unlock(&executor->lock);
      continue;
    }
    char *encoded = task->encoded;
    unsigned char *password = task->password;
    size_t password_length = task->password_length;
    task->encoded = NULL;
    task->password = NULL;
    task->password_length = 0;
    executor->running++;
    atomic_store_explicit(&task->state, AUTH_TASK_RUNNING, memory_order_release);
    pthread_mutex_unlock(&executor->lock);
#ifdef MOONBIT_MQTT_AUTH_EXECUTOR_TESTING
    while (atomic_load_explicit(&executor->test_running_hold, memory_order_acquire)) {
      sched_yield();
    }
#endif

    int64_t started = monotonic_ns();
    int status = moonbit_mqtt_argon2_verify(encoded, password, password_length);
    int64_t finished = monotonic_ns();
    release_inputs(encoded, password, password_length);

    pthread_mutex_lock(&executor->lock);
    if (atomic_load_explicit(&task->cancel_requested, memory_order_acquire)) {
      task->result = MOONBIT_MQTT_AUTH_FINISHED_AFTER_CANCEL;
    } else if (status == 0) {
      task->result = MOONBIT_MQTT_AUTH_MATCHED;
    } else if (status == -35) {
      task->result = MOONBIT_MQTT_AUTH_MISMATCHED;
    } else if (status == -1000) {
      task->result = MOONBIT_MQTT_AUTH_BACKEND_UNAVAILABLE;
    } else {
      task->result = MOONBIT_MQTT_AUTH_INTERNAL_FAILURE;
    }
    task->verify_ns = finished >= started ? finished - started : 0;
    executor->running--;
    executor->active--;
    atomic_store_explicit(&task->state, AUTH_TASK_COMPLETED, memory_order_release);
    promote_queued(executor);
    pthread_cond_broadcast(&executor->wake);
    pthread_mutex_unlock(&executor->lock);
  }
}

moonbit_mqtt_auth_executor *moonbit_mqtt_auth_executor_create(
  int workers,
  int queue_limit
) {
  if (workers < 1 || workers > AUTH_EXECUTOR_MAX_WORKERS ||
      queue_limit < 0 || queue_limit > AUTH_EXECUTOR_MAX_RECORDS - workers ||
      moonbit_mqtt_argon2_initialize() != 0) {
    return NULL;
  }
  moonbit_mqtt_auth_executor *executor = calloc(1, sizeof(*executor));
  if (executor == NULL) {
    return NULL;
  }
  executor->worker_count = workers;
  executor->queue_limit = queue_limit;
  executor->capacity = workers + queue_limit;
  executor->accepting = 1;
  executor->threads = calloc((size_t)workers, sizeof(*executor->threads));
  executor->tasks = calloc((size_t)executor->capacity, sizeof(*executor->tasks));
  if (executor->threads == NULL || executor->tasks == NULL) {
    free(executor->tasks);
    free(executor->threads);
    free(executor);
    return NULL;
  }
  if (pthread_mutex_init(&executor->lock, NULL) != 0) {
    free(executor->tasks);
    free(executor->threads);
    free(executor);
    return NULL;
  }
  if (pthread_cond_init(&executor->wake, NULL) != 0) {
    pthread_mutex_destroy(&executor->lock);
    free(executor->tasks);
    free(executor->threads);
    free(executor);
    return NULL;
  }
  for (int index = 0; index < workers; index++) {
#ifdef MOONBIT_MQTT_AUTH_EXECUTOR_TESTING
    int create_status = index == test_fail_create_at
      ? EAGAIN : pthread_create(&executor->threads[index], NULL, auth_worker, executor);
#else
    int create_status = pthread_create(&executor->threads[index], NULL, auth_worker, executor);
#endif
    if (create_status != 0) {
      pthread_mutex_lock(&executor->lock);
      executor->accepting = 0;
      executor->stopping = 1;
      pthread_cond_broadcast(&executor->wake);
      pthread_mutex_unlock(&executor->lock);
      for (int started = 0; started < index; started++) {
        pthread_join(executor->threads[started], NULL);
      }
      pthread_cond_destroy(&executor->wake);
      pthread_mutex_destroy(&executor->lock);
      free(executor->tasks);
      free(executor->threads);
      free(executor);
      return NULL;
    }
    executor->workers_alive++;
  }
  return executor;
}

int moonbit_mqtt_auth_executor_submit(
  moonbit_mqtt_auth_executor *executor,
  int64_t task_id,
  const unsigned char *encoded,
  size_t encoded_length,
  const unsigned char *password,
  size_t password_length
) {
  if (executor == NULL || task_id <= 0 || encoded == NULL || encoded_length == 0 ||
      memchr(encoded, '\0', encoded_length) != NULL ||
      (password == NULL && password_length != 0) || encoded_length == SIZE_MAX) {
    return MOONBIT_MQTT_AUTH_INVALID;
  }
  char *encoded_copy = malloc(encoded_length + 1);
  if (encoded_copy == NULL) {
    return MOONBIT_MQTT_AUTH_NO_MEMORY;
  }
  encoded_copy[0] = '\0';
  unsigned char *password_copy = malloc(password_length == 0 ? 1 : password_length);
  if (password_copy == NULL) {
    release_inputs(encoded_copy, NULL, 0);
    return MOONBIT_MQTT_AUTH_NO_MEMORY;
  }
  memcpy(encoded_copy, encoded, encoded_length);
  encoded_copy[encoded_length] = '\0';
  if (password_length > 0) {
    memcpy(password_copy, password, password_length);
  }
  if (pthread_mutex_trylock(&executor->lock) != 0) {
    release_inputs(encoded_copy, password_copy, password_length);
    return MOONBIT_MQTT_AUTH_RETRY_LATER;
  }
  if (!executor->accepting) {
    pthread_mutex_unlock(&executor->lock);
    release_inputs(encoded_copy, password_copy, password_length);
    return MOONBIT_MQTT_AUTH_STOPPED;
  }
  if (find_task(executor, task_id) != NULL) {
    pthread_mutex_unlock(&executor->lock);
    release_inputs(encoded_copy, password_copy, password_length);
    return MOONBIT_MQTT_AUTH_INVALID;
  }
  auth_task *task = find_state(executor, AUTH_TASK_FREE);
  if (task == NULL) {
    pthread_mutex_unlock(&executor->lock);
    release_inputs(encoded_copy, password_copy, password_length);
    return MOONBIT_MQTT_AUTH_QUEUE_FULL;
  }
  int state;
  if (executor->active < executor->worker_count) {
    state = AUTH_TASK_ASSIGNED;
    executor->active++;
  } else if (executor->queued < executor->queue_limit) {
    state = AUTH_TASK_QUEUED;
    executor->queued++;
  } else {
    pthread_mutex_unlock(&executor->lock);
    release_inputs(encoded_copy, password_copy, password_length);
    return MOONBIT_MQTT_AUTH_QUEUE_FULL;
  }
  task->id = task_id;
  task->encoded = encoded_copy;
  task->password = password_copy;
  task->password_length = password_length;
  task->result = MOONBIT_MQTT_AUTH_INTERNAL_FAILURE;
  task->verify_ns = 0;
  atomic_store_explicit(&task->cancel_requested, 0, memory_order_release);
  atomic_store_explicit(&task->state, state, memory_order_release);
  pthread_cond_signal(&executor->wake);
  pthread_mutex_unlock(&executor->lock);
  return MOONBIT_MQTT_AUTH_SUBMITTED;
}

int moonbit_mqtt_auth_executor_cancel(
  moonbit_mqtt_auth_executor *executor,
  int64_t task_id
) {
  if (executor == NULL || task_id <= 0) {
    return MOONBIT_MQTT_AUTH_CANCEL_UNKNOWN;
  }
  if (pthread_mutex_trylock(&executor->lock) != 0) {
    return MOONBIT_MQTT_AUTH_CANCEL_RETRY_LATER;
  }
  auth_task *task = find_task(executor, task_id);
  if (task == NULL) {
    pthread_mutex_unlock(&executor->lock);
    return MOONBIT_MQTT_AUTH_CANCEL_UNKNOWN;
  }
  int state = atomic_load_explicit(&task->state, memory_order_acquire);
  if (state == AUTH_TASK_RUNNING) {
    atomic_store_explicit(&task->cancel_requested, 1, memory_order_release);
    pthread_mutex_unlock(&executor->lock);
    return MOONBIT_MQTT_AUTH_CANCEL_MARKED_RUNNING;
  }
  if (state == AUTH_TASK_COMPLETED || state == AUTH_TASK_CLEANING) {
    pthread_mutex_unlock(&executor->lock);
    return MOONBIT_MQTT_AUTH_CANCEL_ALREADY_COMPLETED;
  }
  if (state == AUTH_TASK_ASSIGNED) {
    executor->active--;
  } else if (state == AUTH_TASK_QUEUED) {
    executor->queued--;
  } else {
    pthread_mutex_unlock(&executor->lock);
    return MOONBIT_MQTT_AUTH_CANCEL_UNKNOWN;
  }
  atomic_store_explicit(&task->state, AUTH_TASK_CLEANING, memory_order_release);
  promote_queued(executor);
  pthread_cond_broadcast(&executor->wake);
  pthread_mutex_unlock(&executor->lock);
  complete_cleaning_task(task);
  return MOONBIT_MQTT_AUTH_CANCELLED;
}

int moonbit_mqtt_auth_executor_poll(
  moonbit_mqtt_auth_executor *executor,
  int64_t *task_id,
  int *result,
  int64_t *verify_ns
) {
  if (executor == NULL || task_id == NULL || result == NULL || verify_ns == NULL) {
    return MOONBIT_MQTT_AUTH_INVALID;
  }
  if (pthread_mutex_trylock(&executor->lock) != 0) {
    return MOONBIT_MQTT_AUTH_RETRY_LATER;
  }
  auth_task *task = find_state(executor, AUTH_TASK_COMPLETED);
  if (task == NULL) {
    pthread_mutex_unlock(&executor->lock);
    return 0;
  }
  *task_id = task->id;
  *result = task->result;
  *verify_ns = task->verify_ns;
  pthread_mutex_unlock(&executor->lock);
  return 1;
}

int moonbit_mqtt_auth_executor_completion(
  moonbit_mqtt_auth_executor *executor,
  int64_t task_id,
  int *result,
  int64_t *verify_ns
) {
  if (executor == NULL || task_id <= 0 || result == NULL || verify_ns == NULL) {
    return MOONBIT_MQTT_AUTH_INVALID;
  }
  if (pthread_mutex_trylock(&executor->lock) != 0) {
    return MOONBIT_MQTT_AUTH_RETRY_LATER;
  }
  auth_task *task = find_task(executor, task_id);
  if (task == NULL ||
      atomic_load_explicit(&task->state, memory_order_acquire) != AUTH_TASK_COMPLETED) {
    pthread_mutex_unlock(&executor->lock);
    return MOONBIT_MQTT_AUTH_INVALID;
  }
  *result = task->result;
  *verify_ns = task->verify_ns;
  pthread_mutex_unlock(&executor->lock);
  return MOONBIT_MQTT_AUTH_SUBMITTED;
}

int moonbit_mqtt_auth_executor_reap(
  moonbit_mqtt_auth_executor *executor,
  int64_t task_id
) {
  if (executor == NULL || task_id <= 0) {
    return MOONBIT_MQTT_AUTH_INVALID;
  }
  if (pthread_mutex_trylock(&executor->lock) != 0) {
    return MOONBIT_MQTT_AUTH_RETRY_LATER;
  }
  auth_task *task = find_task(executor, task_id);
  if (task == NULL ||
      atomic_load_explicit(&task->state, memory_order_acquire) != AUTH_TASK_COMPLETED) {
    pthread_mutex_unlock(&executor->lock);
    return MOONBIT_MQTT_AUTH_INVALID;
  }
  task->id = 0;
  task->result = MOONBIT_MQTT_AUTH_INTERNAL_FAILURE;
  task->verify_ns = 0;
  atomic_store_explicit(&task->cancel_requested, 0, memory_order_release);
  atomic_store_explicit(&task->state, AUTH_TASK_FREE, memory_order_release);
  pthread_mutex_unlock(&executor->lock);
  return MOONBIT_MQTT_AUTH_SUBMITTED;
}

int moonbit_mqtt_auth_executor_stop(moonbit_mqtt_auth_executor *executor) {
  if (executor == NULL) {
    return MOONBIT_MQTT_AUTH_INVALID;
  }
  if (pthread_mutex_trylock(&executor->lock) != 0) {
    return MOONBIT_MQTT_AUTH_RETRY_LATER;
  }
  executor->accepting = 0;
  executor->stopping = 1;
  pthread_cond_broadcast(&executor->wake);
  pthread_mutex_unlock(&executor->lock);
  return MOONBIT_MQTT_AUTH_SUBMITTED;
}

int moonbit_mqtt_auth_executor_is_stopped(moonbit_mqtt_auth_executor *executor) {
  if (executor == NULL) {
    return 1;
  }
  if (pthread_mutex_trylock(&executor->lock) != 0) {
    return -1;
  }
  int stopped = executor->workers_alive == 0;
  pthread_mutex_unlock(&executor->lock);
  return stopped;
}

int moonbit_mqtt_auth_executor_stats(
  moonbit_mqtt_auth_executor *executor,
  moonbit_mqtt_auth_stats *stats
) {
  if (executor == NULL || stats == NULL) {
    return MOONBIT_MQTT_AUTH_INVALID;
  }
  if (pthread_mutex_trylock(&executor->lock) != 0) {
    return MOONBIT_MQTT_AUTH_RETRY_LATER;
  }
  memset(stats, 0, sizeof(*stats));
  stats->queued = executor->queued;
  stats->running = executor->running;
  stats->workers_alive = executor->workers_alive;
  for (int index = 0; index < executor->capacity; index++) {
    int state = atomic_load_explicit(&executor->tasks[index].state, memory_order_acquire);
    if (state != AUTH_TASK_FREE) {
      stats->nonfree++;
    }
    if (state == AUTH_TASK_ASSIGNED) {
      stats->assigned++;
    }
    if (state == AUTH_TASK_COMPLETED) {
      stats->completed++;
    }
  }
  pthread_mutex_unlock(&executor->lock);
  return MOONBIT_MQTT_AUTH_SUBMITTED;
}

int moonbit_mqtt_auth_executor_destroy(moonbit_mqtt_auth_executor *executor) {
  if (executor == NULL) {
    return MOONBIT_MQTT_AUTH_INVALID;
  }
  pthread_mutex_lock(&executor->lock);
  if (executor->workers_alive != 0) {
    pthread_mutex_unlock(&executor->lock);
    return MOONBIT_MQTT_AUTH_STOPPED;
  }
  pthread_mutex_unlock(&executor->lock);
  for (int index = 0; index < executor->worker_count; index++) {
    pthread_join(executor->threads[index], NULL);
  }
  for (int index = 0; index < executor->capacity; index++) {
    release_inputs(
      executor->tasks[index].encoded,
      executor->tasks[index].password,
      executor->tasks[index].password_length
    );
  }
  pthread_cond_destroy(&executor->wake);
  pthread_mutex_destroy(&executor->lock);
  free(executor->tasks);
  free(executor->threads);
  free(executor);
  return MOONBIT_MQTT_AUTH_SUBMITTED;
}

#ifdef MOONBIT_MQTT_AUTH_EXECUTOR_TESTING
int moonbit_mqtt_auth_executor_test_hold(
  moonbit_mqtt_auth_executor *executor,
  int hold
) {
  pthread_mutex_lock(&executor->lock);
  executor->test_hold = hold;
  pthread_cond_broadcast(&executor->wake);
  pthread_mutex_unlock(&executor->lock);
  return 0;
}
int moonbit_mqtt_auth_executor_test_hold_running(
  moonbit_mqtt_auth_executor *executor,
  int hold
) {
  atomic_store_explicit(&executor->test_running_hold, hold, memory_order_release);
  return 0;
}
#endif
