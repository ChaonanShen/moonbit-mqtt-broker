#include <moonbit.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

int32_t moonbit_utf8_len_from_utf16(
  moonbit_string_t src,
  int32_t src_offset,
  int32_t src_length
);

int32_t moonbit_utf8_encode_from_utf16(
  moonbit_string_t src,
  int32_t src_offset,
  int32_t src_length,
  moonbit_bytes_t dst,
  int32_t dst_offset
);

static volatile sig_atomic_t moonbit_mqtt_shutdown_signal = 0;

static void moonbit_mqtt_handle_shutdown_signal(int signal_number) {
  if (moonbit_mqtt_shutdown_signal == 0) {
    moonbit_mqtt_shutdown_signal = signal_number;
  }
}

MOONBIT_FFI_EXPORT
void moonbit_mqtt_install_shutdown_handlers(void) {
  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_handler = moonbit_mqtt_handle_shutdown_signal;
  sigemptyset(&action.sa_mask);
  sigaction(SIGTERM, &action, NULL);
  sigaction(SIGINT, &action, NULL);
}

MOONBIT_FFI_EXPORT
int32_t moonbit_mqtt_shutdown_requested(void) {
  return moonbit_mqtt_shutdown_signal != 0;
}

MOONBIT_FFI_EXPORT
int32_t moonbit_mqtt_private_key_status(
  moonbit_string_t path,
  int32_t path_length
) {
  int32_t utf8_length = moonbit_utf8_len_from_utf16(path, 0, path_length);
  char *encoded = malloc((size_t)utf8_length + 1);
  if (encoded == NULL) {
    return 4;
  }
  moonbit_utf8_encode_from_utf16(
    path,
    0,
    path_length,
    (moonbit_bytes_t)encoded,
    0
  );
  encoded[utf8_length] = '\0';
  struct stat status;
  int result = 0;
  if (lstat(encoded, &status) != 0) {
    result = 1;
  } else if (!S_ISREG(status.st_mode)) {
    result = 2;
  } else if ((status.st_mode & 0077) != 0) {
    result = 3;
  }
  free(encoded);
  return result;
}
