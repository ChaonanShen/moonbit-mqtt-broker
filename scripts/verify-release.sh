#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
scripts/verify-observability.sh
scripts/verify-qos2.sh
scripts/verify-resource-limits.sh
tests/integration/configuration.sh
tests/integration/transports.sh
tests/integration/durability_transports.sh
tests/integration/durability_commit.sh
tests/integration/durability_migration.sh
tests/integration/management_crypto.sh
tests/integration/management_read.sh --prepared
MANAGEMENT_ADMIN_STRESS=1 tests/integration/management_admin.sh --prepared
tests/integration/management_auth_kick.sh --prepared
tests/integration/management_snapshot_admin.sh --prepared
readonly RELOAD_EVIDENCE_DIR="${RELEASE_ARTIFACT_DIR:-$REPO_ROOT/.local/reload-integration}/reload-$(date -u +%Y%m%dT%H%M%SZ)-$$"
export RELOAD_EVIDENCE_DIR
mkdir -p "$RELOAD_EVIDENCE_DIR"
printf 'candidate_sha=%s\ncommands=%s\n' "${CANDIDATE_SHA:-unbound}" \
  'reload_lifecycle.sh reload_tls.sh reload_durability.sh reload_security.sh(off,snapshot,strict) reload_limits.sh reload_shutdown.sh' \
  >"$RELOAD_EVIDENCE_DIR/reload-metadata.txt"
tests/integration/reload_lifecycle.sh
tests/integration/reload_tls.sh
tests/integration/reload_durability.sh
tests/integration/reload_limits.sh
tests/integration/reload_shutdown.sh
for mode in off snapshot strict; do
  RELOAD_TEST_MODE="$mode" tests/integration/reload_security.sh
done
echo 'RELEASE verification passed'
