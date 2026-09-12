# Release verification runbook

[中文](release-verification.zh_CN.md) | **English**

This is the project's release policy, not a universal Mooncakes requirement. Before publishing or submitting for acceptance, require a complete successful run of [the distribution verifier](../scripts/verify-distribution-docker.sh) for the exact candidate. A development test pass or an intermediate success message is insufficient.

## 1. Purpose and supported environment

An Argon2id fixture previously passed in the development image but aborted through `Result::unwrap()` when `libargon2` was unavailable. The reference CLI reproduced the fixture correctly. This motivated checking the source archive, distributable package and runtime separately.

The supported environment is Ubuntu 24.04, Linux amd64, the native backend, MoonBit compiler `0.10.10+f8a486b6f` and Node.js `22.23.1`, as defined by the Dockerfile. MoonBit dependencies and client tools follow `moon.mod` and the lock files. These results do not establish support for other operating systems, architectures, backends or arbitrary toolchain versions.

Run commands from the Linux repository root, following the applicable workspace instructions. Maintenance uses the remote authoritative workspace; do not create a Windows source copy to reproduce tests.

```bash
git status --short --branch
docker version
docker image inspect moonbit-mqtt-broker-dev --format '{{.Id}}'
scripts/moon-docker.sh version --all
```

Build the development image when it is missing or its definition changes:

```bash
docker build --platform linux/amd64 -t moonbit-mqtt-broker-dev .
```

Allow disk space for fresh volumes, runtime images and evidence. Dependency downloads and image builds need network access to Mooncakes, npm and image/Ubuntu repositories. Only the subsequent runtime containers have external networking disabled. If overriding `MOONBIT_MQTT_IMAGE`, record why, inspect its toolchain, and retain its actual image ID; a tag is not an immutable identity.

| Dependency | Role |
| --- | --- |
| `libargon2-1` | Password authentication and the complete native authentication tests; loads `libargon2.so.1`, with `libargon2.so` as a fallback |
| `libssl3t64` on Ubuntu 24.04 | OpenSSL 3 TLS runtime, including `libssl.so.3` and associated libraries |
| libc / `libgcc-s1` | Native runtime support; inspect the actual executable's `ldd` record |
| `argon2` CLI | Reference fixture generation and integration data, not a required Broker runtime executable |
| MoonBit, compiler, Node/npm, MQTT clients | Development/test tools; their presence in the development image says nothing about an end-user runtime |

Mooncakes does not install OS libraries. An evaluator must use the declared Docker environment or install the declared native dependencies.

## 2. Daily checks, targeted diagnostics and release runs

For uncommitted development changes:

```bash
scripts/moon-docker.sh fmt --check
scripts/moon-docker.sh check --target native --deny-warn
scripts/moon-docker.sh test --target native --deny-warn
scripts/moon-docker.sh build --target native
```

`check` checks types and diagnostics; it does not execute tests. `build` checks code generation/linking. `test` executes behavioral assertions. Target password changes with:

```bash
scripts/moon-docker.sh test src/security/security_test.mbt src/server/broker_runtime_security_test.mbt --target native --deny-warn
docker run --rm --platform linux/amd64 --entrypoint bash \
  --volume "$PWD:/workspace" --workdir /workspace \
  moonbit-mqtt-broker-dev tests/integration/argon2_environment.sh
```

The environment regression independently checks the reference fixture before simulating a missing runtime in child processes. It does not rewrite expected hashes. Do not disable assertions, skip authentication tests or use snapshot updates to accept an unexplained result. See [security](security.md) for fixture generation.

For a release, review and commit the entire candidate, then run:

```bash
git status --short --branch
git log -1 --oneline
scripts/verify-distribution-docker.sh
```

Tracked modifications, including staged changes, block this entry point. Untracked candidate files also block it, except root-level local `AGENTS.md` and `AGENTS.local.md`. The exception preserves local maintenance instructions; those files are still excluded from the committed archive. Never hide source changes in ignored paths or instruction files to bypass the guard.

For a long remote run, choose an unused tmux session name:

```bash
mkdir -p .local
repo_root="$PWD"
tmux new-session -d -s mqtt-release-verify -c "$repo_root" \
  'scripts/verify-distribution-docker.sh >.local/release-launch.log 2>&1'
```

`tail -n 80 .local/release-launch.log` shows startup output and the result path. Reusing this command overwrites that launcher log, but each verifier run has its own result directory. A tmux session ending does not imply success. Do not interrupt another session to reuse its name.

For the extended stability profile:

```bash
RELEASE_SOAK=1 scripts/verify-distribution-docker.sh
```

Defaults are `RELEASE_SOAK_SECONDS=600` and `RELEASE_SOAK_PUBLICATIONS=100000`; the existing stability script supplies the workload assertions. This command runs the entire verifier with soak enabled. Record any parameter overrides explicitly; a shorter custom run is not the default ten-minute profile. The normal command has soak disabled.

## 3. Verification stages

| Stage | Checks |
| --- | --- |
| Freeze candidate | Record complete HEAD and create `source.tar` with `git archive` |
| Isolate source | Extract into a new Docker volume; assert no `.git`, `_build`, `.mooncakes` or root `node_modules`; create a temporary Git index for file enumeration |
| Cumulative checks | Formatting, strict typing, native tests/build/interface generation, protocol oracle, reference brokers, networking, QoS, persistence, bounded workloads, examples, shutdown, TLS/authentication, expiry, observability and configuration |
| Audit ZIP | Required files, allowed paths, excluded caches/credentials/runtime state; limits of 500 files, 20 MiB uncompressed and 10 MiB compressed |
| Rebuild extracted package | Resolve dependencies; check/test/build Debug and Release; check executable version; export the Release executable |
| Runtime matrix | Verify actual libraries; test missing-library failures and real MQTT behavior in independent images |
| Final integrity | Ensure HEAD/tracked files stayed unchanged, verify package/executable hashes, and record completion plus exit status |

The strict builder also runs shutdown cycles and the source secret scan. A fresh source volume does not mean reinstalling the SDK or OS at every stage: the image provides the fixed SDK/core/tools, and normal downloads can be reused inside that build container. The current checkout and its build/dependency directories are not mounted into it. The historical count of 214 tests is not a permanent acceptance target.

## 4. Runtime matrix and expected failures

| Profile | Available optional libraries | Must succeed | Must fail as expected |
| --- | --- | --- | --- |
| `base` | Neither Argon2 nor libssl | Anonymous plaintext QoS 1 | Password configuration; TLS configuration |
| `argon2` | Argon2 only | Password-authenticated plaintext QoS 1 | TLS configuration; bad/missing credentials |
| `tls` | libssl only | Anonymous TLS QoS 1 | Password configuration |
| `full` | Both | Password-authenticated TLS QoS 1 | Bad/missing credentials |

Broker images must contain no MoonBit, compiler, Node/npm, Git or Argon2 CLI. The Broker runs as UID/GID 65532, with a read-only root, writable `/tmp` tmpfs, no external network, reduced privileges and resource limits. A separate client container shares its network namespace and connects over loopback; client dependencies do not enter the Broker filesystem.

`ldd` does not enumerate all `dlopen` dependencies. The verifier also checks `ldconfig` inventories and triggers actual features. Ubuntu base images can include OpenSSL, while coreutils needs `libcrypto` from the same OS package. Negative images therefore remove the target libssl/Argon2 shared objects and refresh the loader cache, retaining unrelated system requirements; positive images reinstall the relevant libraries. Installed-package metadata alone cannot prove absence. These are test scenarios, not production image templates.

A missing-library authentication test must fail, and password-enabled startup without its runtime must fail. The regression harness passes only when those failures have the expected status/diagnostic and do not abort. Never confuse an expected child-process failure with either a successful standalone authentication test or an overall verifier failure.

## 5. Acceptance criteria and evidence

Require all of the following from one run:

1. Complete outer execution with exit status 0.
2. Matching `source_commit`, `completed_at`, `exit_code=0` and four `runtime_*=PASS` fields in one `evidence.txt`.
3. The final `DISTRIBUTION verification passed: committed source, clean package, four isolated runtime profiles` log message.
4. Successful verification of the ZIP and executable against `artifacts.sha256`.
5. No subsequent candidate/version/artifact change; required soak has its own complete successful enabled run.

`RELEASE verification passed` and individual test summaries can be intermediate messages. Do not combine stages from different runs or commits into a claimed overall pass. `DISTRIBUTION_RESULTS=...` identifies a run under `test-results/distribution/<SHA-prefix>-<UTC-time>-<PID>/`. A directory can exist for a failed or unfinished run.

For a complete local result directory, replace the placeholder and check from the repository root:

```bash
(
  set -euo pipefail
  result_dir='test-results/distribution/<RUN_ID>'
  grep -Fx "source_commit=$(git rev-parse HEAD)" "$result_dir/evidence.txt"
  grep -Fx 'exit_code=0' "$result_dir/evidence.txt"
  grep -q '^completed_at=' "$result_dir/evidence.txt"
  for profile in base argon2 tls full; do
    grep -Fx "runtime_${profile}=PASS" "$result_dir/evidence.txt"
  done
  grep -Fq 'DISTRIBUTION verification passed: committed source, clean package, four isolated runtime profiles' "$result_dir/verification.log"
  (cd "$result_dir" && sha256sum --check artifacts.sha256)
)
```

This reads evidence; it does not run omitted stages or publish anything. An early preflight failure may precede result-directory creation; inspect the terminal/launcher log.

| Artifact | Purpose | CI uploads it |
| --- | --- | --- |
| `evidence.txt`, `verification.log` | Identity, parameters, image IDs, stage output and final status | Yes |
| `toolchain.txt`, `dependencies.txt` | Actual SDK and resolved module graph | Yes |
| `linked-libraries.txt`, `libraries-*.txt` | Linked and runtime-loaded library inventories | Yes |
| `missing-*.log`, `runtime-*.log` | Negative/positive runtime outcomes; possibly `runtime-failure.log` | Yes |
| `package.zip`, `artifacts.sha256` | Tested package and package/executable digests | Yes |
| `source.tar`, `runtime/broker` | Committed source and exported executable | No |
| Temporary runtime certificates, key and password file | Per-run test fixtures | No |

CI uses artifact name `distribution-evidence` with seven-day retention. Since it does not upload `runtime/broker`, check the uploaded package from the corresponding run directory with `awk '$2 == "package.zip" { print }' artifacts.sha256 | sha256sum --check -`. Missing non-uploaded executable files do not imply a corrupt package.

Keep results on the remote workspace according to project policy. Record the directory, commit, package hash and CI run, and preserve permitted evidence before CI expiry if needed for a release. Do not copy temporary private keys into source, distributables or acceptance submissions; test fixtures are not production credentials.

## 6. Failure handling

| Symptom | Action |
| --- | --- |
| Dirty/untracked candidate guard | Review and commit intended content; never bypass it |
| Missing/wrong development image | Prepare the Dockerfile-defined image and inspect real versions/ID |
| Missing Argon2 runtime | Use the development image or install declared dependencies; retain assertions |
| Fixture mismatch | Check reference generation, accidental password newline and shell `$` expansion; fix and retest |
| Compile/assertion failure or panic | Diagnose the first relevant error, fix the cause and add a meaningful regression |
| Runtime inventory mismatch | Fix the image scenario rather than relaxing assertions |
| Permissions, read-only path, TLS/configuration failure | Check the documented runtime contract; do not simply switch to root or disable certificate verification |
| Registry/package/npm/image download timeout | Record infrastructure failure/incomplete verification; retry the full entry point after recovery |
| Interrupted task or missing completion record | Not a pass; retain output and rerun |
| Commit/hash mismatch | Treat changed content as a new candidate and obtain fresh evidence |

Exit numbers alone are insufficient: 255 has appeared for both network errors and native-process crashes. Use the stage and actual diagnostic. A retry must keep all checks. Normal exit attempts to clean its volume/container; after forced interruption inspect only precisely identified resources from this run, not every Docker resource on the shared server.

## 7. Changes that invalidate a result

Recommit and rerun after changes to production code, tests, C FFI, build scripts, manifests/lock files, version/metadata, package file selection, packaged documentation/examples, toolchains/images/system libraries, workload settings or claimed platform support.

Every new native library needs a dependency/version declaration, installation instructions, real positive coverage, a missing-library case and appropriate inventory assertions. Expand the matrix before claiming another OS, architecture or toolchain.

Current scripts still contain `0.1.0` filenames/assertions and legacy tag checks. For a new release, review the manifest, CLI version, CHANGELOG, documentation and affected checks together:

```bash
git grep -n '0\.1\.0' -- moon.mod src/cmd/broker scripts tests/integration README.md README.zh_CN.md CHANGELOG.md
```

Do not blindly replace fixture values or third-party dependency versions. Version changes must precede verification, not follow it immediately before publishing.

## 8. Handoff and publication record

Provide the evaluator with the complete candidate commit, supported environment, reproduction command, final successful result directory, package digest and soak settings. Explicitly state omitted or infrastructure-blocked checks. Other environments and external hidden tests are not covered automatically.

Keep publication consistent with the verified candidate. If a publishing tool regenerates a ZIP, do not assume another file is the tested artifact without checking; changed candidate contents or packaging require verification. Creating `package.zip` does not upload it or guarantee that an existing registry version can be replaced.

```text
Candidate version:
Complete commit:
Verifier command and soak parameters:
UTC start/end:
Development image ID and toolchain:
Runtime results: base / argon2 / tls / full
Final exit status:
Evidence directory / CI run:
package.zip SHA-256:
Untested environments or incomplete checks:
Published version/commit/artifact correspondence:
```

## 9. Entry points and legacy boundaries

- [verify-distribution-docker.sh](../scripts/verify-distribution-docker.sh): canonical release/acceptance entry point, also used by CI.
- [verify-distribution-build.sh](../scripts/verify-distribution-build.sh): internal container step requiring `/workspace` and `/results`, not a host command.
- [verify-release-docker.sh](../scripts/verify-release-docker.sh): existing cumulative regression against the current checkout; useful during development, but lacks the new runtime matrix when run alone.
- [check-package.sh](../scripts/check-package.sh): package audit and reconstruction; strict runs additionally test/export Release output.
- [check-argon2.sh](../scripts/check-argon2.sh) and [argon2_environment.sh](../tests/integration/argon2_environment.sh): fixture and missing-runtime diagnostics.
- [release-gate.sh](../scripts/release-gate.sh): legacy three-pass plus soak workflow; does not automatically invoke the new matrix and cannot replace the strict entry point.
- [release-check.sh](../scripts/release-check.sh): legacy manual preflight with version/tag/record-format assumptions; new evidence is not its old record format.

CI runs on push, pull request and manual dispatch; manual dispatch can enable soak. The job timeout is 45 minutes. Artifacts can be uploaded from failed jobs, so their presence is not evidence of a successful job. Update this runbook with changes to the scripts or CI.

## 10. Historical implementation evidence

This is a 2026-09-07 snapshot, not a live assertion that future HEADs pass:

- Fix `4c1a396`: Debug/Release each 214 tests, authentication/ACL/TLS/restart/configuration integration checks and C FFI ASan/UBSan passed.
- The first strict run passed cumulative source and extracted-package Debug/Release checks, then correctly rejected a base image unexpectedly containing OpenSSL.
- After correcting negative images, all four runtime profiles passed independently.
- Final implementation commit `9c693c0` had two complete-run attempts fail with Mooncakes Git-index and dependency-ZIP network timeouts, both exit 255. No complete pass was claimed for that commit.
- The default ten-minute soak was not executed then. A release still needs current-candidate complete success evidence.

QoS 2 development verification: scripts/verify-qos2-docker.sh. The cumulative
verify-release.sh (also called by the distribution build) invokes verify-qos2.sh,
including raw handshakes, committed-phase SIGKILL recovery, MQTT.js/Mosquitto,
1,000 publications and 100 reconnects. Worktree results do not replace strict
verification of a committed candidate HEAD in four runtime environments.

The worktree Docker wrapper trusts only /workspace through process-local Git
configuration. This accommodates the host UID/container root mismatch without
changing the host Git configuration or trusting arbitrary directories.

Protocol, security and large-load functional fixtures explicitly disable rate/IP policy where their workload would exceed the new defaults. Byte accounting remains enabled. Dedicated resource tests cover enabled policy; disabling limits in a functional fixture is not evidence that rate admission passed.


## P0-02 resource gate

`scripts/verify-resource-limits-docker.sh` runs all Native tests plus the resource network matrix. The cumulative `verify-release.sh` calls `verify-resource-limits.sh`, so strict distribution/CI includes the gate. Enabled-policy cases cover retained/fanout rollback, QoS2 duplicates and persistent buckets, real Argon2 attempts, pre-TLS IP admission, single-debit raw ingress, slow consumers, non-mutating low-budget restore and failed final snapshots. Only the dedicated high-volume profile disables rate/IP policy; byte accounting stays enabled.

`RESOURCE_RESULTS` records managed-byte assertions, RSS peaks and PING delays. RSS is not the logical byte cap. The FIFO negative test has both a termination and a kill deadline; a timeout is not a passing result.
