#!/usr/bin/env bash
# Native tests must report a missing Argon2 runtime without aborting the process.
# Password configuration must fail closed, while anonymous mode remains usable.
set -euo pipefail
ulimit -c 0
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"
scripts/check-argon2.sh
moon build --target native
readonly BROKER="${REPO_ROOT}/_build/native/debug/build/cmd/broker/broker.exe"
readonly WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
cc -Wall -Wextra -Werror -shared -fPIC tests/fixtures/security/hide_argon2.c \
  -ldl -o "${WORK_DIR}/hide_argon2.so"

status=0
LD_PRELOAD="${WORK_DIR}/hide_argon2.so" moon test \
  src/security/security_test.mbt src/server/broker_runtime_security_test.mbt \
  --target native --deny-warn >"${WORK_DIR}/tests.log" 2>&1 || status=$?
if [[ "${status}" -ne 2 ]] ||
    ! grep -qF 'Argon2id tests require libargon2.so.1' "${WORK_DIR}/tests.log" ||
    grep -Eq 'SIGABRT|PanicError|Result::unwrap' "${WORK_DIR}/tests.log"; then
  cat "${WORK_DIR}/tests.log" >&2
  echo "Missing-library tests did not fail with a normal diagnostic (exit=${status})" >&2
  exit 1
fi

hash="$(printf '%s' 'correct horse' | argon2 '0123456789abcdef' -id -e -t 2 -m 12 -p 1)"
printf 'sensor01:%s\n' "${hash}" >"${WORK_DIR}/passwords"
chmod 0600 "${WORK_DIR}/passwords"
status=0
LD_PRELOAD="${WORK_DIR}/hide_argon2.so" "${BROKER}" --check-config \
  --allow-anonymous false --password-file "${WORK_DIR}/passwords" \
  >"${WORK_DIR}/broker.log" 2>&1 || status=$?
[[ "${status}" -ne 0 && "${status}" -lt 128 ]]
grep -qF 'Argon2id authentication requires libargon2.so.1' "${WORK_DIR}/broker.log"
! grep -Eq 'MQTT broker listening|SIGABRT|PanicError' "${WORK_DIR}/broker.log"
! grep -qF "${hash}" "${WORK_DIR}/broker.log"
LD_PRELOAD="${WORK_DIR}/hide_argon2.so" "${BROKER}" --check-config >"${WORK_DIR}/anonymous.log" 2>&1

echo 'ARGON2 environment verification passed: reference fixtures, missing-library diagnostics, fail-closed authentication, anonymous configuration'
