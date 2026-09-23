#!/usr/bin/env bash
set -euo pipefail
readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
printf 'token1:deadbeef:metrics,read\n' >"${WORK_DIR}/valid"
chmod 0600 "${WORK_DIR}/valid"
head -c 16384 /dev/zero >"${WORK_DIR}/max"
chmod 0600 "${WORK_DIR}/max"
head -c 16385 /dev/zero >"${WORK_DIR}/too-large"
chmod 0600 "${WORK_DIR}/too-large"
head -c 20000 /dev/zero >"${WORK_DIR}/oversize"
chmod 0600 "${WORK_DIR}/oversize"
mkdir "${WORK_DIR}/directory"
mkfifo "${WORK_DIR}/fifo"
ln -s "${WORK_DIR}/valid" "${WORK_DIR}/symlink"
printf 'x\n' >"${WORK_DIR}/permissive"
chmod 0644 "${WORK_DIR}/permissive"
printf 'x\n' >"${WORK_DIR}/foreign"
chmod 0600 "${WORK_DIR}/foreign"
chown 65534:65534 "${WORK_DIR}/foreign"
cc -std=c11 -D_GNU_SOURCE -Wall -Wextra -Werror -I/root/.moon/include \
  src/management_native/native.c tests/integration/management_native_harness.c \
  -ldl -o "${WORK_DIR}/native-harness"
"${WORK_DIR}/native-harness" "${WORK_DIR}"
for failure in EAGAIN ENOSYS; do
  cc -std=c11 -D_GNU_SOURCE -Wall -Wextra -Werror \
    -DFAILURE_ERRNO="${failure}" -I/root/.moon/include \
    src/management_native/native.c tests/integration/management_random_failure.c \
    -ldl -o "${WORK_DIR}/random-${failure}"
  "${WORK_DIR}/random-${failure}"
  echo "${failure} mapping passed"
done
