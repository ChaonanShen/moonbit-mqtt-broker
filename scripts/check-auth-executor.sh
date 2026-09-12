#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

readonly COMPILER="${CC:-cc}"
readonly SANITIZERS="${AUTH_EXECUTOR_SANITIZERS:-address,undefined}"
readonly OUTPUT="$(mktemp)"
trap 'rm -f "${OUTPUT}"' EXIT

flags=(-std=c11 -O1 -g -Wall -Wextra -Werror -pthread)
if [[ -n "${SANITIZERS}" ]]; then
  flags+=("-fsanitize=${SANITIZERS}")
fi
"${COMPILER}" "${flags[@]}" \
  -DMOONBIT_MQTT_AUTH_EXECUTOR_TESTING \
  src/security/argon2_backend.c \
  src/security/auth_executor.c \
  tests/runtime/auth_executor_harness.c \
  -ldl -o "${OUTPUT}"
ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=1:strict_string_checks=1}" \
UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=1}" \
TSAN_OPTIONS="${TSAN_OPTIONS:-halt_on_error=1}" \
  "${OUTPUT}"
