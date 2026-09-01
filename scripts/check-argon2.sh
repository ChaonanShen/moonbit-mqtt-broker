#!/usr/bin/env bash
# Check the independent reference implementation against every embedded fixture.
set -euo pipefail
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
if ! command -v argon2 >/dev/null; then
  echo 'Argon2id fixture verification requires argon2 and libargon2-1 on Ubuntu/Debian, or the project Docker image' >&2
  exit 1
fi
if ! generated="$(printf '%s' 'correct horse' | argon2 '0123456789abcdef' -id -e -t 2 -m 12 -p 1)"; then
  echo 'Argon2id reference generation failed; check the argon2 runtime installation' >&2
  exit 1
fi
for file in src/security/security_test.mbt src/server/broker_runtime_security_test.mbt; do
  mapfile -t hashes < <(sed -n 's/^[[:space:]]*let encoded = "\(\$argon2id\$[^" ]*\)".*/\1/p' "${file}")
  if [[ "${#hashes[@]}" -eq 0 ]]; then
    echo "No Argon2id fixture found in ${file}" >&2
    exit 1
  fi
  for hash in "${hashes[@]}"; do
    if [[ "${hash}" != "${generated}" ]]; then
      echo "Argon2id fixture differs from the reference implementation in ${file}" >&2
      exit 1
    fi
  done
done
echo 'Argon2id fixtures match the reference CLI (v=19, m=4096 KiB, t=2, p=1)'
