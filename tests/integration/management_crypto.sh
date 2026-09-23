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

# Broker process checks: a valid synthetic token source, malformed source,
# permissions and missing libcrypto have distinct startup results.
moon build --target native
readonly BROKER="${ROOT}/_build/native/debug/build/cmd/broker/broker.exe"
readonly CLIENT_TOKEN="spike-token.0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
digest="$(node -e 'const c=require("crypto");process.stdout.write(c.createHash("sha256").update("moonbit-mqtt-broker/admin/v1:"+process.argv[1]).digest("hex"))' "${CLIENT_TOKEN}")"
printf 'spike-token:%s:metrics,read\n' "${digest}" >"${WORK_DIR}/tokens"
chmod 0600 "${WORK_DIR}/tokens"
"${BROKER}" --management-enabled true --management-token-file "${WORK_DIR}/tokens" \
  --check-config | grep -qxF 'configuration valid'
"${BROKER}" --management-enabled true --management-token-file "${WORK_DIR}/tokens" \
  --print-effective-config >"${WORK_DIR}/effective"
grep -qxF 'token_file = "<redacted>"' "${WORK_DIR}/effective"
! grep -qF "${WORK_DIR}/tokens" "${WORK_DIR}/effective"
printf 'spike-token:not-a-hash:metrics\n' >"${WORK_DIR}/invalid-tokens"
chmod 0600 "${WORK_DIR}/invalid-tokens"
if "${BROKER}" --management-enabled true --management-token-file "${WORK_DIR}/invalid-tokens" \
  --check-config >"${WORK_DIR}/invalid.log" 2>&1; then
  echo 'invalid management token file accepted' >&2
  exit 1
fi
grep -qF 'invalid management token file' "${WORK_DIR}/invalid.log"
chmod 0644 "${WORK_DIR}/tokens"
if "${BROKER}" --management-enabled true --management-token-file "${WORK_DIR}/tokens" \
  --check-config >"${WORK_DIR}/permissions.log" 2>&1; then
  echo 'permissive management token file accepted' >&2
  exit 1
fi
grep -qF 'private regular file' "${WORK_DIR}/permissions.log"
chmod 0600 "${WORK_DIR}/tokens"
cc -std=c11 -D_GNU_SOURCE -Wall -Wextra -Werror -shared -fPIC \
  tests/integration/management_crypto_missing.c -ldl \
  -o "${WORK_DIR}/missing-libcrypto.so"
if LD_PRELOAD="${WORK_DIR}/missing-libcrypto.so" \
  "${BROKER}" --management-enabled true --management-token-file "${WORK_DIR}/tokens" \
  --check-config >"${WORK_DIR}/missing-libcrypto.log" 2>&1; then
  echo 'enabled management unexpectedly survived missing libcrypto' >&2
  exit 1
fi
grep -qF 'management authentication requires libcrypto.so.3' "${WORK_DIR}/missing-libcrypto.log"
! grep -Eq 'PanicError|SIGABRT' "${WORK_DIR}/missing-libcrypto.log"
LD_PRELOAD="${WORK_DIR}/missing-libcrypto.so" \
  "${BROKER}" --check-config | grep -qxF 'configuration valid'
echo 'management crypto startup and disabled missing-library cases passed'
