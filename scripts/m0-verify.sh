#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

moon version --all
node --version
{ mosquitto_sub --help 2>&1 || true; } | sed -n '1p'
moon update
npm ci --prefix tools/codec_oracle --ignore-scripts
npm ci --prefix tests/integration --ignore-scripts

fixture_snapshot="$(mktemp -d)"
trap 'rm -rf "${fixture_snapshot}"' EXIT
cp -a tests/fixtures/codec/. "${fixture_snapshot}/"
npm run generate --prefix tools/codec_oracle
diff -ru "${fixture_snapshot}" tests/fixtures/codec
npm run verify --prefix tools/codec_oracle
moon fmt --check
moon check --target native
moon test --target native
moon build --target native
moon run --target native src/cmd/codec_gate
tests/integration/m0_connect.sh

package_files="$(moon package --list 2>&1)"
if grep -Eq '(\.local\.|node_modules|test-results|\.env)' <<<"${package_files}"; then
  echo 'Mooncakes package contains an excluded local or generated file' >&2
  exit 1
fi
echo 'M0 verification passed'
