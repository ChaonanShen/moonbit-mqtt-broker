#!/usr/bin/env bash
# Script-level tests with an explicitly fake moon command; not compiler results.
set -euo pipefail
readonly REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
mkdir -p .local
case_root="$(mktemp -d "${REPO_ROOT}/.local/dependency-retry-test.XXXXXX")"
trap 'rm -rf -- "$case_root"' EXIT
mkdir "$case_root/bin"
cat >"$case_root/bin/moon" <<'FAKE'
#!/usr/bin/env bash
[[ "$1" = update ]] && exit 0
count="$(cat "$MOON_TEST_COUNTER")"
count=$((count+1)); echo "$count" >"$MOON_TEST_COUNTER"
if [[ "$MOON_TEST_CASE" = retry && "$count" -ge 2 ]]; then exit 0; fi
if [[ "$MOON_TEST_CASE" = type ]]; then echo 'Error: type mismatch'; exit 1; fi
echo 'When installing packages: error sending request for url (https://example.invalid/package.zip): operation timed out'
exit 255
FAKE
chmod +x "$case_root/bin/moon"
for case_name in retry type network; do
  counter="$case_root/${case_name}.count"; echo 0 >"$counter"
  status=0
  PATH="$case_root/bin:$PATH" MOON_TEST_COUNTER="$counter" MOON_TEST_CASE="$case_name" \
    MOON_DEPENDENCY_ATTEMPTS=3 MOON_DEPENDENCY_RETRY_SECONDS=0 \
    scripts/prepare-moon-dependencies.sh "$case_root/$case_name" >"$case_root/$case_name.out" 2>&1 || status=$?
  case "$case_name" in
    retry) [[ "$status" = 0 && "$(cat "$counter")" = 2 ]] ;;
    type) [[ "$status" = 1 && "$(cat "$counter")" = 1 ]] ;;
    network) [[ "$status" = 255 && "$(cat "$counter")" = 3 ]] ;;
  esac
done
echo 'Dependency retry guards passed: transient retry, compiler fail-fast, bounded failure'
