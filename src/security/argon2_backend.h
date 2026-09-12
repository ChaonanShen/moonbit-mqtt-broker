#ifndef MOONBIT_MQTT_ARGON2_BACKEND_H
#define MOONBIT_MQTT_ARGON2_BACKEND_H

#include <stddef.h>

int moonbit_mqtt_argon2_initialize(void);
int moonbit_mqtt_argon2_verify(
  const char *encoded,
  const void *password,
  size_t password_length
);

#endif
