#!/usr/bin/env bash
# Verify exactly HEAD: no checkout files/caches reach the candidate or runtime.
# Never publishes, tags, pushes, or reads registry credentials.
set -Eeuo pipefail
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo 'Commit tracked changes before distribution verification; the candidate must be exactly HEAD' >&2
  exit 1
fi
while IFS= read -r -d '' file; do
  case "${file}" in
    AGENTS.md|AGENTS.local.md) ;; # Local workspace instructions are not distribution sources.
    *) echo "Untracked candidate file must be committed or ignored first: ${file}" >&2; exit 1 ;;
  esac
done < <(git ls-files --others --exclude-standard -z)
command -v python3 >/dev/null || { echo 'Python 3 is required on the Docker host for release reference validation tests' >&2; exit 1; }
readonly SOURCE_SHA="$(git rev-parse HEAD)"
readonly RUN_ID="${SOURCE_SHA:0:12}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
readonly DEV_IMAGE="${MOONBIT_MQTT_IMAGE:-moonbit-mqtt-broker-dev}"
readonly RESULTS="${REPO_ROOT}/test-results/distribution/${RUN_ID}"
readonly SOURCE_VOLUME="moonbit-mqtt-distribution-${RUN_ID}"
readonly BROKER_CONTAINER="moonbit-mqtt-runtime-${RUN_ID}"
mkdir -p "${RESULTS}"
exec > >(tee "${RESULTS}/verification.log") 2>&1
volume_created=0
broker_started=0
finish() {
  local status=$?
  trap - EXIT
  if [[ "${broker_started}" -eq 1 ]]; then
    docker logs "${BROKER_CONTAINER}" >"${RESULTS}/runtime-failure.log" 2>&1 || true
    docker rm --force "${BROKER_CONTAINER}" >/dev/null 2>&1 || true
  fi
  if [[ "${volume_created}" -eq 1 ]]; then
    docker volume rm "${SOURCE_VOLUME}" >/dev/null || true
  fi
  printf 'exit_code=%s\ncompleted_at=%s\n' "${status}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"${RESULTS}/evidence.txt"
  printf 'DISTRIBUTION_EXIT=%s\nDISTRIBUTION_RESULTS=%s\n' "${status}" "${RESULTS}"
  exit "${status}"
}
trap finish EXIT
trap 'printf "DISTRIBUTION_FAILED_AT_LINE=%s\n" "$LINENO" >&2' ERR
python3 -B tools/runtime_reference_test.py
scripts/test-dependency-retry.sh
printf 'source_commit=%s\nstarted_at=%s\nsoak=%s\n' "${SOURCE_SHA}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${RELEASE_SOAK:-0}" >"${RESULTS}/evidence.txt"
readonly RUNTIME_REFERENCE="${DISTRIBUTION_RUNTIME_REFERENCE:-}"
if [[ -n "${RUNTIME_REFERENCE}" ]]; then
  python3 -B tools/runtime_reference.py --repo "${REPO_ROOT}" --reference "${RUNTIME_REFERENCE}" --head "${SOURCE_SHA}" >"${RESULTS}/runtime-reference.json"
  readonly RUNTIME_REFERENCE_SHA="$(sha256sum "${RESULTS}/runtime-reference.json" | awk '{print $1}')"
  echo 'runtime_image_mode=verified-cache-reference' >>"${RESULTS}/evidence.txt"
  sha256sum "${RESULTS}/runtime-reference.json" >>"${RESULTS}/evidence.txt"
else
  echo 'runtime_image_mode=build' >>"${RESULTS}/evidence.txt"
fi
docker image inspect "${DEV_IMAGE}" --format 'toolchain_image={{.Id}}' >>"${RESULTS}/evidence.txt"
git archive --format=tar "${SOURCE_SHA}" >"${RESULTS}/source.tar"
sha256sum "${RESULTS}/source.tar" >>"${RESULTS}/evidence.txt"
docker volume create "${SOURCE_VOLUME}" >/dev/null
volume_created=1
docker run --rm --entrypoint tar --volume "${SOURCE_VOLUME}:/workspace" \
  --volume "${RESULTS}:/results:ro" --workdir /workspace "${DEV_IMAGE}" -xf /results/source.tar
docker run --rm --platform linux/amd64 --entrypoint bash \
  --volume "${SOURCE_VOLUME}:/workspace" --volume "${RESULTS}:/results" --workdir /workspace \
  --env "RELEASE_SOAK=${RELEASE_SOAK:-0}" \
  --env "RELEASE_SOAK_SECONDS=${RELEASE_SOAK_SECONDS:-600}" \
  --env "RELEASE_SOAK_PUBLICATIONS=${RELEASE_SOAK_PUBLICATIONS:-100000}" \
  "${DEV_IMAGE}" scripts/verify-distribution-build.sh

runtime_options=(--platform linux/amd64 --network none --read-only \
  --tmpfs /tmp:rw,nosuid,nodev,mode=1777 --cap-drop ALL \
  --security-opt no-new-privileges --pids-limit 64 --memory 256m \
  --volume "${RESULTS}/runtime:/artifact:ro")
for profile in base argon2 tls full; do
  if [[ -n "${RUNTIME_REFERENCE}" ]]; then
    runtime_image="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["images"][sys.argv[2]])' "${RESULTS}/runtime-reference.json" "${profile}")"
    echo "Using verified unchanged runtime context for ${profile}: ${runtime_image}"
  else
    runtime_image="moonbit-mqtt-runtime-${profile}:${SOURCE_SHA:0:12}"
    # The build context contains only committed runtime image definitions.
    git archive "${SOURCE_SHA}" tests/runtime | docker build --platform linux/amd64 \
      --file tests/runtime/Dockerfile --target "${profile}" --tag "${runtime_image}" -
  fi
  docker image inspect "${runtime_image}" --format "runtime_${profile}_image={{.Id}}" >>"${RESULTS}/evidence.txt"
  docker run --rm "${runtime_options[@]}" --entrypoint sh "${runtime_image}" -c \
    'for cmd in moon moonc cc gcc node npm git argon2; do if command -v "$cmd" >/dev/null; then echo "unexpected development tool: $cmd" >&2; exit 1; fi; done; ldd /artifact/broker; /sbin/ldconfig -p' \
    >"${RESULTS}/libraries-${profile}.txt"
  ! grep -q 'not found' "${RESULTS}/libraries-${profile}.txt"
  has_argon2=0; has_tls=0
  [[ "${profile}" = argon2 || "${profile}" = full ]] && has_argon2=1
  [[ "${profile}" = tls || "${profile}" = full ]] && has_tls=1
  # Assert actual library absence/presence; client dependencies cannot mask it.
  actual_argon2=0; actual_tls=0
  grep -q 'libargon2.so' "${RESULTS}/libraries-${profile}.txt" && actual_argon2=1
  grep -q 'libssl.so' "${RESULTS}/libraries-${profile}.txt" && actual_tls=1
  if [[ "${has_argon2}" -ne "${actual_argon2}" || "${has_tls}" -ne "${actual_tls}" ]]; then
    echo "Runtime ${profile} has unexpected libraries: argon2=${actual_argon2} (expected ${has_argon2}), TLS=${actual_tls} (expected ${has_tls})" >&2
    exit 1
  fi
  for feature in argon2 tls; do
    enabled="${has_argon2}"
    feature_args=(--allow-anonymous false --password-file /artifact/passwords)
    expected='Argon2id authentication requires libargon2.so.1'
    if [[ "${feature}" = tls ]]; then
      enabled="${has_tls}"
      feature_args=(--tls-cert /artifact/server.crt --tls-key /artifact/server.key)
      expected='TLS certificate/private key validation failed'
    fi
    if [[ "${enabled}" -eq 0 ]]; then
      status=0
      docker run --rm "${runtime_options[@]}" "${runtime_image}" --check-config \
        "${feature_args[@]}" >"${RESULTS}/missing-${profile}-${feature}.log" 2>&1 || status=$?
      [[ "${status}" -gt 0 && "${status}" -lt 125 ]]
      grep -qF "${expected}" "${RESULTS}/missing-${profile}-${feature}.log"
      ! grep -Eq 'PanicError|SIGABRT|MQTT broker listening' "${RESULTS}/missing-${profile}-${feature}.log"
    fi
  done
  feature_args=(); scheme=mqtt; auth_mode=anonymous
  if [[ "${has_argon2}" -eq 1 ]]; then
    feature_args+=(--allow-anonymous false --password-file /artifact/passwords)
    auth_mode=password
  fi
  if [[ "${has_tls}" -eq 1 ]]; then
    feature_args+=(--tls-cert /artifact/server.crt --tls-key /artifact/server.key)
    scheme=mqtts
  fi
  docker run --detach "${runtime_options[@]}" --name "${BROKER_CONTAINER}" \
    "${runtime_image}" --listen 127.0.0.1:1883 "${feature_args[@]}" >/dev/null
  broker_started=1
  docker run --rm --platform linux/amd64 --network "container:${BROKER_CONTAINER}" \
    --entrypoint node --volume "${SOURCE_VOLUME}:/workspace:ro" \
    --volume "${RESULTS}/runtime:/artifact:ro" --workdir /workspace "${DEV_IMAGE}" \
    tests/integration/distribution_smoke.mjs "${scheme}://127.0.0.1:1883" "${auth_mode}"
  docker stop --time 10 "${BROKER_CONTAINER}" >/dev/null
  [[ "$(docker inspect --format '{{.State.ExitCode}}' "${BROKER_CONTAINER}")" = 0 ]]
  docker logs "${BROKER_CONTAINER}" >"${RESULTS}/runtime-${profile}.log" 2>&1
  docker rm "${BROKER_CONTAINER}" >/dev/null
  broker_started=0
  printf 'runtime_%s=PASS\n' "${profile}" >>"${RESULTS}/evidence.txt"
done
[[ "$(git rev-parse HEAD)" = "${SOURCE_SHA}" ]]
[[ -z "$(git status --porcelain --untracked-files=no)" ]]
(cd "${RESULTS}" && sha256sum --check artifacts.sha256 && sha256sum package.zip runtime/broker) >>"${RESULTS}/evidence.txt"
if [[ -n "${RUNTIME_REFERENCE}" ]]; then
  [[ "$(sha256sum "${RESULTS}/runtime-reference.json" | awk '{print $1}')" = "${RUNTIME_REFERENCE_SHA}" ]]
fi
echo 'DISTRIBUTION verification passed: committed source, clean package, four isolated runtime profiles'
