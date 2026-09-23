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
  # Compilation failures are never converted into retries or success. Retry
  # only dependency transport/cache installation failures from this fresh run.
  retryable=false
  if grep -Eiq 'error sending request for url|failed to (fetch|download)|operation timed out|connection reset|could not resolve host|failed to connect to [^ ]+ port [0-9]+|couldn.t connect to server' "$log" &&
     grep -Eiq 'https?://|registry|installing packages|dependency graph' "$log"; then
    retryable=true
  elif grep -Eiq 'invalid cross-device link' "$log"; then
    retryable=true
  fi
  if [[ "$retryable" != true ]]; then
    exit "$status"
  fi
  if [[ "$attempt" = "$ATTEMPTS" ]]; then exit "$status"; fi
  echo "Retrying transient dependency download (${attempt}/${ATTEMPTS})" >&2
  sleep "$DELAY"
done
exit 1
