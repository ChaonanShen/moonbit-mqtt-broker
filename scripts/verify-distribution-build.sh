#!/usr/bin/env bash
# Container-side build from a committed archive in a new Docker volume.
set -euo pipefail
cd /workspace
[[ -d /results ]]
[[ ! -e .git && ! -e _build && ! -e .mooncakes && ! -e node_modules ]]
git init --quiet
git add --all
export RELEASE_ARTIFACT_DIR=/results
scripts/prepare-moon-dependencies.sh /results/dependency-fetch-source
scripts/verify-release.sh
tests/integration/shutdown_cycles.sh
scripts/check-secrets.sh
test -x /results/runtime/broker
test -s /results/package.zip
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 2 \
  -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
  -keyout /results/runtime/server.key -out /results/runtime/server.crt >/dev/null 2>&1
hash="$(printf '%s' 'correct horse' | argon2 '0123456789abcdef' -id -e -t 2 -m 12 -p 1)"
printf 'sensor01:%s\n' "${hash}" >/results/runtime/passwords
# These are ephemeral test credentials, readable by the unprivileged runtime UID.
chown 65532:65532 /results/runtime/server.key /results/runtime/passwords
chmod 0400 /results/runtime/server.key /results/runtime/passwords
chmod 0444 /results/runtime/server.crt
# Independent test principal. The Broker reads only the digest file; the
# client token is mounted into the separate verifier and Prometheus containers.
management_token='distread.0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
management_digest="$(printf 'moonbit-mqtt-broker/admin/v1:%s' "${management_token}" | sha256sum | awk '{print $1}')"
printf 'distread:%s:metrics,read\n' "${management_digest}" >/results/runtime/management-tokens
printf '%s\n' "${management_token}" >/results/runtime/management-client-token
chown 65532:65532 /results/runtime/management-tokens
chmod 0400 /results/runtime/management-tokens
chmod 0444 /results/runtime/management-client-token
(cd /results && sha256sum package.zip runtime/broker >artifacts.sha256)
echo 'DISTRIBUTION clean source, release archive, and exported native binary passed'
