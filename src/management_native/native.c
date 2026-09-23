// Bounded native operations for the optional loopback management listener.
// All management secrets and file bytes stay in explicit caller-owned buffers.

#include <moonbit.h>

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/random.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

// OpenSSL 3 EVP_Digest(data, count, md, size, type, impl).
typedef int (*evp_digest_fn)(
  const void *data,
  size_t count,
  unsigned char *md,
  unsigned int *size,
  const void *type,
  void *impl
);
typedef const void *(*evp_sha256_fn)(void);
typedef int (*crypto_memcmp_fn)(const void *a, const void *b, size_t len);

static evp_digest_fn resolved_evp_digest = NULL;
static evp_sha256_fn resolved_evp_sha256 = NULL;
static crypto_memcmp_fn resolved_crypto_memcmp = NULL;
static void *resolved_crypto_library = NULL;

static int32_t
initialize_from_library(const char *name) {
  void *library = dlopen(name, RTLD_NOW | RTLD_LOCAL);
  if (library == NULL) {
    return -1;
  }
  evp_digest_fn digest = (evp_digest_fn)dlsym(library, "EVP_Digest");
  evp_sha256_fn sha256 = (evp_sha256_fn)dlsym(library, "EVP_sha256");
  crypto_memcmp_fn memcmp_fn =
    (crypto_memcmp_fn)dlsym(library, "CRYPTO_memcmp");
  if (digest == NULL || sha256 == NULL || memcmp_fn == NULL) {
    dlclose(library);
    return -2;
  }
  resolved_evp_digest = digest;
  resolved_evp_sha256 = sha256;
  resolved_crypto_memcmp = memcmp_fn;
  resolved_crypto_library = library;
  return 0;
}

MOONBIT_FFI_EXPORT
int32_t
moonbit_mqtt_management_crypto_initialize(void) {
  if (resolved_evp_digest != NULL) {
    return 0;
  }
  return initialize_from_library("libcrypto.so.3");
}

MOONBIT_FFI_EXPORT
int32_t
moonbit_mqtt_management_hash_token(
  moonbit_bytes_t input,
  int32_t input_length,
  char *output,
  int32_t output_length
) {
  if (input_length < 0 || input_length > 128) {
    return -3;
  }
  if (output_length != 32) {
    return -5;
  }
  if (resolved_evp_digest == NULL) {
    return -1000;
  }
  unsigned int produced = 0;
  int rc = resolved_evp_digest(
    input,
    (size_t)input_length,
    (unsigned char *)output,
    &produced,
    resolved_evp_sha256(),
    NULL
  );
  if (rc != 1 || produced != 32u) {
    return -4;
  }
  return 0;
}

MOONBIT_FFI_EXPORT
int32_t
moonbit_mqtt_management_constant_time_equal32(
  char *left,
  int32_t left_length,
  char *right,
  int32_t right_length
) {
  if (left_length != 32 || right_length != 32) {
    return -5;
  }
  if (resolved_crypto_memcmp == NULL) {
    return -1000;
  }
  return resolved_crypto_memcmp(left, right, 32) == 0 ? 1 : 0;
}

MOONBIT_FFI_EXPORT
int32_t
moonbit_mqtt_management_secure_random(char *output, int32_t length) {
  if (length < 1 || length > 32) {
    return -3;
  }
  int32_t done = 0;
  int retries = 0;
  while (done < length) {
    ssize_t rc =
      getrandom(output + done, (size_t)(length - done), GRND_NONBLOCK);
    if (rc < 0) {
      if (errno == EINTR) {
        if (++retries > 4) {
          return -13;
        }
        continue;
      }
      if (errno == EAGAIN) {
        return -10;
      }
#ifdef ENOSYS
      if (errno == ENOSYS) {
        return -11;
      }
#endif
      return -12;
    }
    if (rc == 0) {
      return -12;
    }
    done += (int32_t)rc;
  }
  return 0;
}

// Returns bytes read (>= 0) or a negative error. The caller sizes `out` to
// max_content + 1 so this function can distinguish "exactly full" from
// "too large": any byte beyond out_capacity is reported as -28.
MOONBIT_FFI_EXPORT
int32_t
moonbit_mqtt_management_read_token_file(
  moonbit_bytes_t path,
  int32_t path_length,
  char *out,
  int32_t out_capacity
) {
  if (path_length <= 0 || path_length > 4096 ||
      memchr(path, '\0', (size_t)path_length) != NULL) {
    return -20;
  }
  char *path_copy = malloc((size_t)path_length + 1);
  if (path_copy == NULL) {
    return -29;
  }
  memcpy(path_copy, path, (size_t)path_length);
  path_copy[path_length] = '\0';
  int fd = open(path_copy, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
  int saved_errno = errno;
  free(path_copy);
  if (fd < 0) {
    if (saved_errno == ELOOP) {
      return -21;
    }
    if (saved_errno == ENOENT) {
      return -22;
    }
    return -23;
  }
  struct stat st;
  if (fstat(fd, &st) != 0) {
    close(fd);
    return -24;
  }
  if (!S_ISREG(st.st_mode)) {
    close(fd);
    return -25;
  }
  if (st.st_uid != geteuid()) {
    close(fd);
    return -26;
  }
  if ((st.st_mode & 0077) != 0) {
    close(fd);
    return -27;
  }
  int32_t done = 0;
  int retries = 0;
  for (;;) {
    if (done >= out_capacity) {
      char probe;
      ssize_t rc = read(fd, &probe, 1);
      if (rc == 0) {
        break;
      }
      if (rc > 0) {
        close(fd);
        return -28;
      }
      if (errno == EINTR && ++retries <= 4) {
        continue;
      }
      close(fd);
      return -29;
    }
    ssize_t rc = read(fd, out + done, (size_t)(out_capacity - done));
    if (rc < 0) {
      if (errno == EINTR) {
        if (++retries > 4) {
          close(fd);
          return -29;
        }
        continue;
      }
      close(fd);
      return -29;
    }
    if (rc == 0) {
      break;
    }
    done += (int32_t)rc;
  }
  close(fd);
  return done;
}
