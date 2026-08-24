#!/usr/bin/env bash
set -euo pipefail
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
if git ls-files | grep -E '(^|/)(\.env($|\.)|broker\.snapshot($|\.)|broker\.snapshot\.lock$|credentials($|/))'; then
  echo 'tracked runtime secret/state path found' >&2
  exit 1
fi
if rg -l --hidden 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY' \
  --glob '!_build/**' --glob '!.mooncakes/**' --glob '!**/node_modules/**' .; then
  echo 'private key material found in source tree' >&2
  exit 1
fi
echo 'M11 secret and runtime-artifact scan passed'
