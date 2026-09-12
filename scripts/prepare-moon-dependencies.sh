#!/usr/bin/env bash
# Fetch only through the normal pinned registry resolver in this current tree.
set -uo pipefail
readonly REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
readonly LOG_DIR="${1:-${REPO_ROOT}/.local/dependency-fetch}"
readonly ATTEMPTS="${MOON_DEPENDENCY_ATTEMPTS:-4}"
readonly DELAY="${MOON_DEPENDENCY_RETRY_SECONDS:-2}"
[[ "$ATTEMPTS" =~ ^[1-5]$ && "$DELAY" =~ ^[0-9]+$ ]] || exit 2
mkdir -p "$LOG_DIR"
for ((attempt=1; attempt<=ATTEMPTS; attempt++)); do
  log="$LOG_DIR/attempt-${attempt}.log"
  status=0
  moon update >"$log" 2>&1 || status=$?
  if [[ "$status" = 0 ]]; then
    moon check --target native --deny-warn >>"$log" 2>&1 || status=$?
  fi
  cat "$log"
  if [[ "$status" = 0 ]]; then
    echo "Pinned dependencies ready after attempt ${attempt}; full verification follows"
    exit 0
  fi
  # Compilation failures are never converted into retries or success. A retry
  # only fills the same fresh run's dependency cache, not the host workspace's.
  if ! grep -Eiq 'error sending request for url|failed to (fetch|download)|operation timed out|connection reset|could not resolve host' "$log" ||
     ! grep -Eiq 'https?://|registry|installing packages|dependency graph' "$log"; then
    exit "$status"
  fi
  if [[ "$attempt" = "$ATTEMPTS" ]]; then exit "$status"; fi
  echo "Retrying transient dependency download (${attempt}/${ATTEMPTS})" >&2
  sleep "$DELAY"
done
exit 1
