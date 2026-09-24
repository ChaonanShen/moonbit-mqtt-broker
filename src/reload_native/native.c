#define _POSIX_C_SOURCE 200809L
#include <moonbit.h>

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

typedef void *(*ctx_new_fn)(void);
typedef void (*ctx_free_fn)(void *);
typedef const void *(*sha256_fn)(void);
typedef int (*digest_init_fn)(void *, const void *, void *);
typedef int (*digest_update_fn)(void *, const void *, size_t);
typedef int (*digest_final_fn)(void *, unsigned char *, unsigned int *);

static pthread_once_t crypto_once = PTHREAD_ONCE_INIT;
static void *crypto_library;
static ctx_new_fn ctx_new;
static ctx_free_fn ctx_free;
static sha256_fn sha256;
static digest_init_fn digest_init;
static digest_update_fn digest_update;
static digest_final_fn digest_final;

typedef const void *(*tls_server_method_fn)(void);
typedef void *(*ssl_ctx_new_fn)(const void *);
typedef void (*ssl_ctx_free_fn)(void *);
typedef int (*ssl_ctx_use_chain_fn)(void *, const char *);
typedef int (*ssl_ctx_use_key_fn)(void *, const char *, int);
typedef int (*ssl_ctx_check_key_fn)(const void *);
typedef const void *(*ssl_ctx_certificate_fn)(const void *);
typedef const void *(*x509_time_fn)(const void *);
typedef int (*x509_cmp_time_fn)(const void *);
typedef void (*ssl_ctx_password_cb_fn)(void *, int (*)(char *, int, int, void *));

static pthread_once_t tls_once = PTHREAD_ONCE_INIT;
static void *tls_library;
static tls_server_method_fn tls_server_method;
static ssl_ctx_new_fn ssl_ctx_new;
static ssl_ctx_free_fn ssl_ctx_free;
static ssl_ctx_use_chain_fn ssl_ctx_use_chain;
static ssl_ctx_use_key_fn ssl_ctx_use_key;
static ssl_ctx_check_key_fn ssl_ctx_check_key;
static ssl_ctx_certificate_fn ssl_ctx_certificate;
static x509_time_fn x509_not_before;
static x509_time_fn x509_not_after;
static x509_cmp_time_fn x509_cmp_time;
static ssl_ctx_password_cb_fn ssl_ctx_password_cb;

static int deny_key_password(char *buffer, int size, int rwflag, void *data) {
  (void)buffer; (void)size; (void)rwflag; (void)data;
  return 0;
}

static void load_tls(void) {
  void *library = dlopen("libssl.so.3", RTLD_NOW | RTLD_LOCAL);
  if (library == NULL || crypto_library == NULL) return;
  tls_server_method =
    (tls_server_method_fn)dlsym(library, "TLS_server_method");
  ssl_ctx_new = (ssl_ctx_new_fn)dlsym(library, "SSL_CTX_new");
  ssl_ctx_free = (ssl_ctx_free_fn)dlsym(library, "SSL_CTX_free");
  ssl_ctx_use_chain = (ssl_ctx_use_chain_fn)dlsym(
    library, "SSL_CTX_use_certificate_chain_file"
  );
  ssl_ctx_use_key =
    (ssl_ctx_use_key_fn)dlsym(library, "SSL_CTX_use_PrivateKey_file");
  ssl_ctx_check_key =
    (ssl_ctx_check_key_fn)dlsym(library, "SSL_CTX_check_private_key");
  ssl_ctx_certificate =
    (ssl_ctx_certificate_fn)dlsym(library, "SSL_CTX_get0_certificate");
  ssl_ctx_password_cb = (ssl_ctx_password_cb_fn)dlsym(
    library, "SSL_CTX_set_default_passwd_cb"
  );
  x509_not_before =
    (x509_time_fn)dlsym(crypto_library, "X509_get0_notBefore");
  x509_not_after =
    (x509_time_fn)dlsym(crypto_library, "X509_get0_notAfter");
  x509_cmp_time =
    (x509_cmp_time_fn)dlsym(crypto_library, "X509_cmp_current_time");
  if (tls_server_method == NULL || ssl_ctx_new == NULL ||
      ssl_ctx_free == NULL || ssl_ctx_use_chain == NULL ||
      ssl_ctx_use_key == NULL || ssl_ctx_check_key == NULL ||
      ssl_ctx_certificate == NULL || ssl_ctx_password_cb == NULL ||
      x509_not_before == NULL || x509_not_after == NULL ||
      x509_cmp_time == NULL) {
    dlclose(library);
    return;
  }
  tls_library = library;
}

static void load_crypto(void) {
  void *library = dlopen("libcrypto.so.3", RTLD_NOW | RTLD_LOCAL);
  if (library == NULL) return;
  ctx_new = (ctx_new_fn)dlsym(library, "EVP_MD_CTX_new");
  ctx_free = (ctx_free_fn)dlsym(library, "EVP_MD_CTX_free");
  sha256 = (sha256_fn)dlsym(library, "EVP_sha256");
  digest_init = (digest_init_fn)dlsym(library, "EVP_DigestInit_ex");
  digest_update = (digest_update_fn)dlsym(library, "EVP_DigestUpdate");
  digest_final = (digest_final_fn)dlsym(library, "EVP_DigestFinal_ex");
  if (ctx_new == NULL || ctx_free == NULL || sha256 == NULL ||
      digest_init == NULL || digest_update == NULL || digest_final == NULL) {
    dlclose(library);
    ctx_new = NULL;
    return;
  }
  crypto_library = library;
}

static void clear_bytes(void *pointer, size_t length) {
  volatile unsigned char *bytes = pointer;
  while (length-- > 0) *bytes++ = 0;
}

enum { IDLE = 0, ASSIGNED = 1, RUNNING = 2, COMPLETE = 3 };
enum { JOB_FILE = 1, JOB_TLS = 2 };
enum {
  CAPTURE_OK = 0, CAPTURE_UNSAFE = 1, CAPTURE_CHANGED = 2,
  CAPTURE_TOO_LARGE = 3, CAPTURE_IO = 4, CAPTURE_CANCELLED = 5,
  CAPTURE_CRYPTO = 6, CAPTURE_TLS_INVALID = 7
};

typedef struct {
  pthread_mutex_t lock;
  pthread_cond_t wake;
  pthread_t thread;
  int stopping;
  int alive;
  int state;
  int cancel;
  int64_t id;
  int job_kind;
  char *path;
  unsigned char *cert;
  unsigned char *key;
  int cert_length;
  int key_length;
  char directory[128];
  int directory_taken;
  int max_bytes;
  int private_file;
  unsigned char *data;
  int length;
  unsigned char digest[32];
  int result;
} capture_worker;

static int same_source(const struct stat *a, const struct stat *b) {
  return a->st_dev == b->st_dev && a->st_ino == b->st_ino &&
    a->st_mode == b->st_mode && a->st_uid == b->st_uid &&
    a->st_size == b->st_size &&
    a->st_mtim.tv_sec == b->st_mtim.tv_sec &&
    a->st_mtim.tv_nsec == b->st_mtim.tv_nsec &&
    a->st_ctim.tv_sec == b->st_ctim.tv_sec &&
    a->st_ctim.tv_nsec == b->st_ctim.tv_nsec;
}

static int source_stat(int fd, int max_bytes, int private_file,
                       struct stat *out) {
  if (fstat(fd, out) != 0) return CAPTURE_IO;
  if (!S_ISREG(out->st_mode) ||
      (private_file &&
       (out->st_uid != geteuid() || (out->st_mode & 0077) != 0))) {
    return CAPTURE_UNSAFE;
  }
  if (out->st_size < 1 || out->st_size > max_bytes) return CAPTURE_TOO_LARGE;
  return CAPTURE_OK;
}

static int capture(capture_worker *worker) {
  int fd = open(worker->path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
  if (fd < 0) return CAPTURE_UNSAFE;
  struct stat before, after, current;
  int status = source_stat(fd, worker->max_bytes, worker->private_file,
                           &before);
  if (status != CAPTURE_OK) {
    close(fd);
    return status;
  }
  unsigned char *data = malloc((size_t)worker->max_bytes + 1);
  void *ctx = ctx_new();
  if (data == NULL || ctx == NULL || digest_init(ctx, sha256(), NULL) != 1) {
    free(data);
    if (ctx != NULL) ctx_free(ctx);
    close(fd);
    return CAPTURE_CRYPTO;
  }
  int length = 0;
  while (status == CAPTURE_OK) {
    pthread_mutex_lock(&worker->lock);
    int cancelled = worker->cancel;
    pthread_mutex_unlock(&worker->lock);
    if (cancelled) {
      status = CAPTURE_CANCELLED;
      break;
    }
    unsigned char buffer[4096];
    ssize_t got = read(fd, buffer, sizeof(buffer));
    if (got < 0 && errno == EINTR) continue;
    if (got < 0) {
      status = CAPTURE_IO;
      break;
    }
    if (got == 0) break;
    if (got > worker->max_bytes - length) {
      status = CAPTURE_TOO_LARGE;
      break;
    }
    memcpy(data + length, buffer, (size_t)got);
    length += (int)got;
    if (digest_update(ctx, buffer, (size_t)got) != 1) {
      status = CAPTURE_CRYPTO;
      break;
    }
  }
  if (status == CAPTURE_OK) {
    int path_fd = open(worker->path,
                       O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fstat(fd, &after) != 0 || path_fd < 0 ||
        fstat(path_fd, &current) != 0 ||
        !same_source(&before, &after) ||
        !same_source(&before, &current) ||
        length != before.st_size) {
      status = CAPTURE_CHANGED;
    }
    if (path_fd >= 0) close(path_fd);
  }
  close(fd);
  unsigned int digest_length = 0;
  if (status == CAPTURE_OK &&
      (digest_final(ctx, worker->digest, &digest_length) != 1 ||
       digest_length != 32u)) status = CAPTURE_CRYPTO;
  ctx_free(ctx);
  if (status == CAPTURE_OK) {
    worker->data = data;
    worker->length = length;
  } else {
    clear_bytes(data, (size_t)worker->max_bytes + 1);
    free(data);
  }
  return status;
}

static int cancelled(capture_worker *worker) {
  pthread_mutex_lock(&worker->lock);
  int value = worker->cancel;
  pthread_mutex_unlock(&worker->lock);
  return value;
}

static void release_tls_directory(const char *directory) {
  if (strncmp(directory, "/tmp/moonbit-mqtt-tls-", 21) != 0 ||
      strchr(directory + 21, '/') != NULL) return;
  char cert_path[160], key_path[160];
  snprintf(cert_path, sizeof(cert_path), "%s/cert.pem", directory);
  snprintf(key_path, sizeof(key_path), "%s/key.pem", directory);
  unlink(cert_path);
  unlink(key_path);
  rmdir(directory);
}

static int write_private_bytes(
  capture_worker *worker, const char *path,
  const unsigned char *data, int length
) {
  int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (fd < 0) return CAPTURE_IO;
  int status = CAPTURE_OK;
  int offset = 0;
  while (offset < length) {
    if (cancelled(worker)) {
      status = CAPTURE_CANCELLED;
      break;
    }
    int count = length - offset;
    if (count > 4096) count = 4096;
    ssize_t wrote = write(fd, data + offset, (size_t)count);
    if (wrote < 0 && errno == EINTR) continue;
    if (wrote <= 0) {
      status = CAPTURE_IO;
      break;
    }
    offset += (int)wrote;
  }
  if (close(fd) != 0) status = CAPTURE_IO;
  if (status != CAPTURE_OK) unlink(path);
  return status;
}

static int validate_tls_pair(const char *cert_path, const char *key_path) {
  pthread_once(&tls_once, load_tls);
  if (tls_library == NULL) return CAPTURE_CRYPTO;
  void *ctx = ssl_ctx_new(tls_server_method());
  if (ctx == NULL) return CAPTURE_TLS_INVALID;
  ssl_ctx_password_cb(ctx, deny_key_password);
  int valid = ssl_ctx_use_chain(ctx, cert_path) == 1 &&
    ssl_ctx_use_key(ctx, key_path, 1) == 1 &&
    ssl_ctx_check_key(ctx) == 1;
  if (valid) {
    const void *certificate = ssl_ctx_certificate(ctx);
    const void *not_before = certificate == NULL ? NULL :
      x509_not_before(certificate);
    const void *not_after = certificate == NULL ? NULL :
      x509_not_after(certificate);
    valid = not_before != NULL && not_after != NULL &&
      x509_cmp_time(not_before) < 0 &&
      x509_cmp_time(not_after) > 0;
  }
  ssl_ctx_free(ctx);
  return valid ? CAPTURE_OK : CAPTURE_TLS_INVALID;
}

static int materialize_tls(capture_worker *worker) {
  char directory[] = "/tmp/moonbit-mqtt-tls-XXXXXX";
  if (mkdtemp(directory) == NULL) return CAPTURE_IO;
  char cert_path[160], key_path[160];
  snprintf(cert_path, sizeof(cert_path), "%s/cert.pem", directory);
  snprintf(key_path, sizeof(key_path), "%s/key.pem", directory);
  int status = write_private_bytes(
    worker, cert_path, worker->cert, worker->cert_length
  );
  if (status == CAPTURE_OK) {
    status = write_private_bytes(worker, key_path, worker->key, worker->key_length);
  }
  if (status == CAPTURE_OK && cancelled(worker)) status = CAPTURE_CANCELLED;
  if (status == CAPTURE_OK) {
    status = validate_tls_pair(cert_path, key_path);
  }
  if (status == CAPTURE_OK && cancelled(worker)) status = CAPTURE_CANCELLED;
  if (status != CAPTURE_OK) {
    release_tls_directory(directory);
    return status;
  }
  size_t length = strlen(directory);
  worker->data = malloc(length + 1);
  if (worker->data == NULL) {
    release_tls_directory(directory);
    return CAPTURE_IO;
  }
  memcpy(worker->data, directory, length + 1);
  worker->length = (int)length;
  worker->max_bytes = (int)length;
  memcpy(worker->directory, directory, length + 1);
  memset(worker->digest, 0, 32);
  return CAPTURE_OK;
}

static void *worker_main(void *argument) {
  capture_worker *worker = argument;
  pthread_mutex_lock(&worker->lock);
  for (;;) {
    while (worker->state != ASSIGNED && !worker->stopping)
      pthread_cond_wait(&worker->wake, &worker->lock);
    if (worker->state != ASSIGNED && worker->stopping) {
      worker->alive = 0;
      pthread_mutex_unlock(&worker->lock);
      return NULL;
    }
    worker->state = RUNNING;
    int cancelled = worker->cancel;
    pthread_mutex_unlock(&worker->lock);
    int result = cancelled ? CAPTURE_CANCELLED :
      (worker->job_kind == JOB_TLS ? materialize_tls(worker) : capture(worker));
    pthread_mutex_lock(&worker->lock);
    if (worker->cancel && result == CAPTURE_OK) {
      if (worker->job_kind == JOB_TLS) release_tls_directory(worker->directory);
      clear_bytes(worker->data, (size_t)worker->max_bytes + 1);
      free(worker->data);
      worker->data = NULL;
      worker->length = 0;
      result = CAPTURE_CANCELLED;
    }
    worker->result = result;
    worker->state = COMPLETE;
    pthread_cond_broadcast(&worker->wake);
  }
}

static capture_worker *from_handle(int64_t handle) {
  return handle > 0 ? (capture_worker *)(uintptr_t)handle : NULL;
}

MOONBIT_FFI_EXPORT
int64_t moonbit_mqtt_capture_worker_create(void) {
  pthread_once(&crypto_once, load_crypto);
  if (crypto_library == NULL) return 0;
  capture_worker *worker = calloc(1, sizeof(*worker));
  if (worker == NULL) return 0;
  if (pthread_mutex_init(&worker->lock, NULL) != 0) {
    free(worker);
    return 0;
  }
  if (pthread_cond_init(&worker->wake, NULL) != 0) {
    pthread_mutex_destroy(&worker->lock);
    free(worker);
    return 0;
  }
  worker->alive = 1;
  if (pthread_create(&worker->thread, NULL, worker_main, worker) != 0) {
    pthread_cond_destroy(&worker->wake);
    pthread_mutex_destroy(&worker->lock);
    free(worker);
    return 0;
  }
  return (int64_t)(uintptr_t)worker;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_mqtt_capture_worker_submit(
  int64_t handle, int64_t id, moonbit_bytes_t path, int32_t path_length,
  int32_t max_bytes, int32_t private_file
) {
  capture_worker *worker = from_handle(handle);
  if (worker == NULL || id <= 0 || path_length < 1 || path_length > 4096 ||
      max_bytes < 1 || max_bytes > 1048576 ||
      memchr(path, '\0', (size_t)path_length) != NULL) return -1;
  char *copy = malloc((size_t)path_length + 1);
  if (copy == NULL) return -2;
  memcpy(copy, path, (size_t)path_length);
  copy[path_length] = '\0';
  pthread_mutex_lock(&worker->lock);
  if (worker->stopping || worker->state != IDLE) {
    pthread_mutex_unlock(&worker->lock);
    free(copy);
    return 1;
  }
  worker->path = copy;
  worker->id = id;
  worker->job_kind = JOB_FILE;
  worker->max_bytes = max_bytes;
  worker->private_file = private_file != 0;
  worker->cancel = 0;
  worker->result = CAPTURE_IO;
  worker->state = ASSIGNED;
  pthread_cond_signal(&worker->wake);
  pthread_mutex_unlock(&worker->lock);
  return 0;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_mqtt_capture_worker_submit_tls(
  int64_t handle, int64_t id,
  moonbit_bytes_t cert, int32_t cert_length,
  moonbit_bytes_t key, int32_t key_length
) {
  capture_worker *worker = from_handle(handle);
  if (worker == NULL || id <= 0 || cert_length < 1 || key_length < 1 ||
      cert_length > 1048576 || key_length > 1048576) return -1;
  unsigned char *cert_copy = malloc((size_t)cert_length);
  unsigned char *key_copy = malloc((size_t)key_length);
  if (cert_copy == NULL || key_copy == NULL) {
    free(cert_copy); free(key_copy); return -2;
  }
  memcpy(cert_copy, cert, (size_t)cert_length);
  memcpy(key_copy, key, (size_t)key_length);
  pthread_mutex_lock(&worker->lock);
  if (worker->stopping || worker->state != IDLE) {
    pthread_mutex_unlock(&worker->lock);
    clear_bytes(cert_copy, (size_t)cert_length);
    clear_bytes(key_copy, (size_t)key_length);
    free(cert_copy); free(key_copy);
    return 1;
  }
  worker->id = id;
  worker->job_kind = JOB_TLS;
  worker->cert = cert_copy;
  worker->key = key_copy;
  worker->cert_length = cert_length;
  worker->key_length = key_length;
  worker->directory[0] = '\0';
  worker->directory_taken = 0;
  worker->cancel = 0;
  worker->result = CAPTURE_IO;
  worker->state = ASSIGNED;
  pthread_cond_signal(&worker->wake);
  pthread_mutex_unlock(&worker->lock);
  return 0;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_mqtt_capture_worker_take_tls_directory(
  int64_t handle, int64_t id
) {
  capture_worker *worker = from_handle(handle);
  if (worker == NULL) return -1;
  pthread_mutex_lock(&worker->lock);
  int result = -1;
  if (worker->state == COMPLETE && worker->id == id &&
      worker->job_kind == JOB_TLS && worker->result == CAPTURE_OK &&
      !worker->directory_taken) {
    worker->directory_taken = 1;
    result = 0;
  }
  pthread_mutex_unlock(&worker->lock);
  return result;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_mqtt_capture_worker_cancel(int64_t handle, int64_t id) {
  capture_worker *worker = from_handle(handle);
  if (worker == NULL) return -1;
  pthread_mutex_lock(&worker->lock);
  int result = -1;
  if (worker->state != IDLE && worker->id == id) {
    worker->cancel = 1;
    result = worker->state == COMPLETE ? 1 : 0;
  }
  pthread_mutex_unlock(&worker->lock);
  return result;
}

MOONBIT_FFI_EXPORT
int64_t moonbit_mqtt_capture_worker_poll(int64_t handle) {
  capture_worker *worker = from_handle(handle);
  if (worker == NULL) return -1;
  pthread_mutex_lock(&worker->lock);
  int64_t result = worker->state == COMPLETE ? worker->id : 0;
  pthread_mutex_unlock(&worker->lock);
  return result;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_mqtt_capture_worker_result_info(
  int64_t handle, int64_t id, char *digest_output, int32_t digest_capacity
) {
  capture_worker *worker = from_handle(handle);
  if (worker == NULL || digest_capacity != 32) return -1;
  pthread_mutex_lock(&worker->lock);
  int result = -1;
  if (worker->state == COMPLETE && worker->id == id) {
    if (worker->result != CAPTURE_OK) {
      result = -10 - worker->result;
    } else {
      memcpy(digest_output, worker->digest, 32);
      result = worker->length;
    }
  }
  pthread_mutex_unlock(&worker->lock);
  return result;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_mqtt_capture_worker_copy_chunk(
  int64_t handle, int64_t id, int32_t offset, char *output, int32_t capacity
) {
  capture_worker *worker = from_handle(handle);
  if (worker == NULL || offset < 0 || capacity < 1 || capacity > 4096)
    return -1;
  pthread_mutex_lock(&worker->lock);
  int result = -1;
  if (worker->state == COMPLETE && worker->id == id &&
      worker->result == CAPTURE_OK && offset <= worker->length) {
    result = worker->length - offset;
    if (result > capacity) result = capacity;
    memcpy(output, worker->data + offset, (size_t)result);
  }
  pthread_mutex_unlock(&worker->lock);
  return result;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_mqtt_capture_worker_reap(int64_t handle, int64_t id) {
  capture_worker *worker = from_handle(handle);
  if (worker == NULL) return -1;
  pthread_mutex_lock(&worker->lock);
  if (worker->state != COMPLETE || worker->id != id) {
    pthread_mutex_unlock(&worker->lock);
    return 1;
  }
  if (worker->job_kind == JOB_TLS && !worker->directory_taken &&
      worker->directory[0] != '\0') {
    release_tls_directory(worker->directory);
  }
  if (worker->cert != NULL) {
    clear_bytes(worker->cert, (size_t)worker->cert_length);
    free(worker->cert);
    worker->cert = NULL;
  }
  if (worker->key != NULL) {
    clear_bytes(worker->key, (size_t)worker->key_length);
    free(worker->key);
    worker->key = NULL;
  }
  if (worker->data != NULL) {
    clear_bytes(worker->data, (size_t)worker->max_bytes + 1);
    free(worker->data);
    worker->data = NULL;
  }
  if (worker->path != NULL) {
    clear_bytes(worker->path, strlen(worker->path));
    free(worker->path);
    worker->path = NULL;
  }
  clear_bytes(worker->digest, 32);
  worker->length = 0;
  worker->cert_length = 0;
  worker->key_length = 0;
  worker->directory[0] = '\0';
  worker->directory_taken = 0;
  worker->job_kind = 0;
  worker->id = 0;
  worker->state = IDLE;
  pthread_cond_broadcast(&worker->wake);
  pthread_mutex_unlock(&worker->lock);
  return 0;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_mqtt_capture_worker_stop(int64_t handle) {
  capture_worker *worker = from_handle(handle);
  if (worker == NULL) return -1;
  pthread_mutex_lock(&worker->lock);
  worker->stopping = 1;
  if (worker->state == ASSIGNED || worker->state == RUNNING)
    worker->cancel = 1;
  pthread_cond_broadcast(&worker->wake);
  int done = !worker->alive;
  pthread_mutex_unlock(&worker->lock);
  return done;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_mqtt_capture_worker_destroy(int64_t handle) {
  capture_worker *worker = from_handle(handle);
  if (worker == NULL) return -1;
  pthread_mutex_lock(&worker->lock);
  int ready = !worker->alive && worker->state == IDLE;
  pthread_mutex_unlock(&worker->lock);
  if (!ready) return 1;
  pthread_join(worker->thread, NULL);
  pthread_cond_destroy(&worker->wake);
  pthread_mutex_destroy(&worker->lock);
  free(worker);
  return 0;
}
