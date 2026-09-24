# Release verification runbook

[中文](release-verification.zh_CN.md) | **English**

This is the project's release policy, not a universal Mooncakes requirement. Before publishing or submitting for acceptance, require a complete successful run of [the distribution verifier](../scripts/verify-distribution-docker.sh) for the exact candidate. A development test pass or an intermediate success message is insufficient.

## 1. Purpose and supported environment

An Argon2id fixture previously passed in the development image but aborted through `Result::unwrap()` when `libargon2` was unavailable. The reference CLI reproduced the fixture correctly. This motivated checking the source archive, distributable package and runtime separately.

The supported environment is Ubuntu 24.04, Linux amd64, the native backend, MoonBit compiler `0.10.10+f8a486b6f` and Node.js `22.23.1`, as defined by the Dockerfile. MoonBit dependencies and client tools follow `moon.mod` and the lock files. These results do not establish support for other operating systems, architectures, backends or arbitrary toolchain versions.

Development and user-run tests use the remote authoritative workspace. GitHub Actions may temporarily check out a pushed candidate for automated verification; this is not another development workspace. Preserve CI logs and safe artifacts in Actions; when the user later requests review, archive required evidence to the remote workspace within retention. Do not create a Windows source copy.

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

## 2. Branch development, CI verification and user-run checks

Start every new development task on a new remote task branch after reading instructions and checking HEAD/status/diff; preserve existing changes and record the base SHA. Do not commit or push directly to main. An authorized feature implementation includes committing and pushing its task branch to trigger CI without requesting permission for each push. It does not authorize merging, force-pushing, release tags or publication. A planning/document-only task does not automatically push.

Track implementation, CI, remaining user-run checks and formal acceptance separately. CI owns complete correctness and other suitable automated verification; do not duplicate the full suite on the development machine. For mandatory checks not covered by suitable CI, the agent supplies real commands and logging launch scripts tied to the final candidate SHA. For all future feature implementations and related fixes, the default stopping point is a successful task-branch push, immediately followed by delivery of branch/SHA, the Actions entry or an already available run link, and user test launch/live-log/result commands. End the turn then; do not wait for CI or user tests, run watch/poll loops, create automatic monitors/follow-ups, or enter a post-push repair loop. Review results only after a later user request or notification that tests have run.

During development, select a few tests or process scenarios that directly address the current risk, or a necessary compile/link check. Combine adjacent changes. Commits, small steps and feature-group boundaries do not trigger extra development-side tests; pushing the task branch triggers the configured CI. These commands are options, not a checklist for every change:

```bash
scripts/moon-docker.sh fmt --check
scripts/moon-docker.sh check --target native --deny-warn
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

Prove high-risk boundaries when wiring them: WAL commit/recovery, revocation, native-task reap, protocol order, resource accounting and new library dependencies. Evidence may come from current-candidate CI; development-side runs are limited to implementation decisions and minimal failure reproductions. Missing evidence must not be called a pass.

Once the feature, necessary tests, scripts and documentation are ready, push the task branch and default to one complete functional run for that capability in CI without a full development-side pre-run, covering every applicable functional invariant and affected compatibility case. After fixes settle, rerun affected coverage only if the fixes affect previously verified behavior; use a complete functional rerun for broad or inseparable effects. Do not schedule a second complete run in advance or impose a hard debugging limit.

Functional development completion is separate from formal release-candidate acceptance. The complete functional run is not the full repository release chain, four-profile distribution, long soak or complete performance comparison. If a ready capability proceeds directly to formal acceptance, its functional gate inside the strict chain can serve both purposes without a duplicate run before or after. Capabilities accepted together on the same candidate can share one strict chain.

Matrix IDs identify assertions, not independent executions. Map multiple IDs to one case/process gate or still-valid development evidence with a recorded SHA, configuration and change-impact assessment. Do not duplicate 10,000-request stress, performance or four-profile runs per ID or feature group. All gates inside the strict entry point still run. Every actual run records its purpose, candidate SHA (plus diff/content identity for an uncommitted tree), command, parameters, log path and exit status. Keep handoffs short; do not rerun just to fill a record when there is no code change, risk change or failure to investigate.

After the feature, tests, scripts and documentation are ready, commit and push the task branch so CI invokes the strict entry point below. It already includes cumulative correctness, package reconstruction and four runtime profiles; do not run it on the development machine before pushing or repeat it there after CI succeeds.

```bash
# Runs on the checked-out CI candidate, not a developer pre-push checklist.
git status --short --branch
git log -1 --oneline
scripts/verify-distribution-docker.sh
```

The entry point validates actual HEAD. Tracked modifications and uncommitted candidate files block it, except root-level local AGENTS.local.md (the guard also permits a legacy AGENTS.md), which remains outside the archive. Never hide candidate source in ignored paths.

Ending implementation after push is not an acceptance pass. Formal acceptance still requires one complete successful strict record for the same SHA and artifacts, all four profiles, hashes and outer exit status 0. Qualified CI evidence satisfies this requirement without another remote full run. Distinguish a PR's temporary merge SHA, branch HEAD and release SHA; changed candidates need new evidence, not a combination of partial runs.

The existing push/PR workflow runs strict distribution even though an ordinary Git commit is not formal acceptance. Required performance/soak is supplied by suitable jobs or inputs. A successful push does not imply passing verification.

Prefer CI with soak enabled when the extended stability profile is required:

```bash
RELEASE_SOAK=1 scripts/verify-distribution-docker.sh
```

Defaults are `RELEASE_SOAK_SECONDS=600` and `RELEASE_SOAK_PUBLICATIONS=100000`; the existing stability script supplies the workload assertions. This command runs the entire verifier with soak enabled. Run performance or long workloads on suitable CI runners after the behavior exists, for a concrete performance risk or a formal candidate. Only mandatory checks requiring unsupported hardware/storage or otherwise not covered by suitable CI are handed to the user with exact commands; the agent does not run these complete/long checks for the user. First use a short targeted load to check fixture connectivity/rate limits, bounded waits, sampling and cleanup, then perform one formal measurement. Keep the measurement protocol's paired rounds, thresholds and required soak duration. A fixture failure is a fixture failure/incomplete measurement, not a product failure: diagnose it, fix it and repeat the short check before another long run. Run performance and soak separately without overlapping loads. If soak is required, enable it in the strict run from the outset rather than first running the same candidate's full chain without soak.

Record any parameter overrides explicitly; a shorter custom run is not the default ten-minute profile. The normal command has soak disabled.

### User-run command handoff and durable logs

For every remaining mandatory check, provide its CI coverage gap, candidate SHA, prerequisites, estimated resources/duration, exact launch/live-log/result commands and acceptance criteria. Prepare a remote `run-<case>.sh` with real implemented commands and no placeholders. The user starts it through tmux or the existing scheduler. After a successful branch push the agent hands over these commands and stops without waiting for CI or launching the complete/long run. If no extra manual test is required, state that explicitly and still stop. A failed push must be reported as a failure, not as submitted CI.

- Create a unique run directory and launcher log on every attempt, for example `.local/manual-verification/<capability>/<SHA>/<run-id>/`. Never overwrite a shared `release-launch.log`.
- Persist stdout/stderr from startup, command/parameters, SHA, relevant environment/image identity, start/end time, task ID, raw samples, child logs and actual exit status. Keep evidence outside disposable containers; exclude credentials and full environment dumps.
- Write output directly to the log and use a separate `tail -F` for viewing. Pipelines must preserve the test's exit status. Failures, interruptions and retries keep separate evidence; do not delete prior output.
- Do not switch branches or edit the candidate during a user run. Arrange an isolated committed-candidate environment first if development must continue concurrently. Verify candidate identity at both ends. Missing completion records, including after SIGKILL, mean incomplete; a vanished tmux session is not a pass.
- Only after a later user request to inspect CI, or notification supplying RUN_DIR/session/launcher-log identity, does the agent resume evidence review; do not poll or wait after handoff. For user tests, read remote evidence and checks command, complete output, exit status, assertions/thresholds, raw data and hashes. Report verified, failed or incomplete with precise gaps. Do not ask for repeated full log pastes or silently restart the full suite.

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
| `source.tar` | Committed source archive | No |
| `runtime/broker` | Exported executable for hash verification | Yes |
| Temporary runtime certificates, key and password file | Per-run test fixtures | No |

CI uploads artifact `distribution-evidence` with 30-day retention, including `package.zip`, `artifacts.sha256`, and `runtime/broker`. Verify both files from the artifact directory with `sha256sum --check artifacts.sha256`. When the user later requests review, archive required evidence to remote `.local/ci-evidence/<SHA>/<run-id>/` within retention and record run/job URLs; do not wait for CI or create an automatic follow-up to archive it during the implementation turn.

Keep results on the remote workspace according to project policy. Record the directory, commit, package hash and CI run, and preserve permitted evidence before CI expiry if needed for a release. Do not copy temporary private keys into source, distributables or acceptance submissions; test fixtures are not production credentials.

## 6. Failure handling

| Symptom | Action |
| --- | --- |
| Dirty/untracked candidate guard | Review and commit intended content; never bypass it |
| Missing/wrong development image | Prepare the Dockerfile-defined image and inspect real versions/ID |
| Missing Argon2 runtime | Use the development image or install declared dependencies; retain assertions |
| Fixture mismatch or workload-harness failure | Check reference data, password newline/`$` expansion, rate limits, bounded waits and cleanup; fix and retest narrowly. Do not classify it as a product failure. After fixes settle, formal acceptance still needs a complete strict run |
| Compile/assertion failure or panic | Diagnose the first relevant error, fix the cause and add a meaningful regression |
| Runtime inventory mismatch | Fix the image scenario rather than relaxing assertions |
| Permissions, read-only path, TLS/configuration failure | Check the documented runtime contract; do not simply switch to root or disable certificate verification |
| Registry/package/npm/image download timeout | Record infrastructure failure/incomplete verification; retry the full entry point after recovery |
| Interrupted task or missing completion record | Not a pass; retain output and rerun |
| Commit/hash mismatch | Treat changed content as a new candidate and obtain fresh evidence |

Exit numbers alone are insufficient: 255 has appeared for both network errors and native-process crashes. Use the stage and actual diagnostic. For formal acceptance, a retry must keep all checks; first diagnose and retest narrowly, then retry the complete strict entry point after related fixes settle. Do not combine incomplete runs into a pass. Normal exit attempts to clean its volume/container; after forced interruption inspect only precisely identified resources from this run, not every Docker resource on the shared server.

## 7. Changes that invalidate a result

The old formal result is invalidated by the changes below. Recommit and obtain a new complete successful strict run when the fixes have settled and the candidate is submitted for formal acceptance; this does not require an immediate strict run after every development edit. This applies to production code, tests, C FFI, build scripts, manifests/lock files, version/metadata, package file selection, packaged documentation/examples, toolchains/images/system libraries, workload settings or claimed platform support.

Every new native library needs a dependency/version declaration, installation instructions, real positive coverage, a missing-library case and appropriate inventory assertions. Expand the matrix before claiming another OS, architecture or toolchain.

Release metadata for version 0.2.0 is deliberately checked across the manifest, CLI, system metrics, package filenames, CHANGELOG, documentation and affected tests:

```bash
git grep -n 0\.2\.0 -- moon.mod src/cmd/broker scripts tests/integration README.md README.zh_CN.md CHANGELOG.md
```

Do not blindly replace fixture values or third-party dependency versions. Version changes must precede verification, not follow it immediately before publishing.

## 8. Handoff and publication record

Provide the evaluator with the complete candidate commit, supported environment, reproduction command, final successful result directory, package digest and soak settings. Explicitly state omitted or infrastructure-blocked checks. Other environments and external hidden tests are not covered automatically.

Keep publication consistent with the verified candidate. If a publishing tool regenerates a ZIP, do not assume another file is the tested artifact without checking; changed candidate contents or packaging require verification. Creating `package.zip` does not upload it or guarantee that an existing registry version can be replaced.

After a successful soak run, pass its result directory as `RELEASE_EVIDENCE_DIR` and its `package.zip` as `RELEASE_PACKAGE_PATH` to `scripts/release-check.sh`. The preflight confirms that the commit, four runtime profiles, hashes and package all describe the same candidate.

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
- [release-check.sh](../scripts/release-check.sh): read-only final preflight that matches the package to strict four-profile soak evidence and the candidate commit.

CI runs the complete strict chain on push, pull request and manual dispatch. Push/PR runs for the same branch share a concurrency group, so newer development runs cancel older ones; manually dispatched formal runs use distinct groups and are preserved. An ordinary local commit does not trigger GitHub CI. Manual dispatch can enable soak. The job timeout is 75 minutes. Artifacts can be uploaded from failed jobs, so their presence is not evidence of a successful job. Update this runbook with changes to the scripts or CI.

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


## Resource budgets and authentication isolation gates

`scripts/verify-resource-limits-docker.sh` runs all Native tests plus the resource network matrix. The cumulative `verify-release.sh` calls `verify-resource-limits.sh`, so strict distribution/CI includes the gate. Enabled-policy cases cover retained/fanout rollback, QoS2 duplicates and persistent buckets, real Argon2 attempts, pre-TLS IP admission, single-debit raw ingress, slow consumers, non-mutating low-budget restore and failed final snapshots. Only the dedicated high-volume profile disables rate/IP policy; byte accounting stays enabled.

`scripts/verify-auth-isolation-docker.sh` runs the sanitizer-backed W/Q executor harness and a real Argon2id m=32768 KiB, t=10, p=1 network load. It requires multiple QoS 1 PUBACKs to complete while a password verification is still outstanding, observes bounded ServerUnavailable rejections at W=1/Q=1, then verifies recovery and worker shutdown. The cumulative security gate invokes the same check.

`RESOURCE_RESULTS` records managed-byte assertions, RSS peaks and PING delays. RSS is not the logical byte cap. The FIFO negative test has both a termination and a kill deadline; a timeout is not a passing result.


## Explicit verified runtime cache references

When registry/proxy access is unavailable and a successful local four-profile result exists, one run may explicitly set `DISTRIBUTION_RUNTIME_REFERENCE` to that result directory under this repository's `test-results/distribution/`. Without it, runtime images are built as usual.

```bash
DISTRIBUTION_RUNTIME_REFERENCE=/absolute/repo/test-results/distribution/<successful-run> \
  RELEASE_SOAK=1 scripts/verify-distribution-docker.sh
```

The resolver requires successful completion, all four PASS fields, a full source commit, immutable SHA-256 image identities and Linux/amd64. The entire `tests/runtime` Git tree must match between reference and candidate. Any mismatch fails closed. The selected digest mapping is saved in `runtime-reference.json` and its hash is rechecked at completion.

Current committed source is still rebuilt, packaged and retested after extraction. All four tool/library inventories, positive traffic, missing-library failures and final artifact hashes still run. Evidence records `runtime_image_mode=verified-cache-reference` and provenance; this does not claim a fresh OS package download or convert an earlier failed attempt into success. Rerun the complete strict entry point, never combine partial runs.

The Docker host requires Python 3 (standard library only) for reference guard tests and resolution. Python is not a broker runtime dependency and is not required in development/runtime containers. The strict entry point checks it before lengthy validation. The resource container gate uses the existing MoonBit, Node, Argon2 CLI and OpenSSL tools.

Clean source and extracted packages prepare pinned dependencies through the normal registry before the full gates. Explicit download/network failures get at most four attempts (configurable from one to five), logged under `dependency-fetch-source/` or `dependency-fetch-package/`. Type/compiler failures stop immediately. No host dependency cache is injected; all full checks run after preparation. Exhausted retries fail the run. Script guards cover transient recovery, compiler fail-fast and bounded persistent failure.

## Management candidate checks

The cumulative release gate runs the original management crypto and read
gates, followed once by `management_admin.sh`, `management_auth_kick.sh`
and `management_snapshot_admin.sh`. The admin gate covers scoped detail
queries, strong ETags, 202/idempotency, precise kick, offline QoS 2 deletion,
audit overwrite/gap, 10,000 protected Operation reads, and slow-reader
shutdown. The auth gate observes a real Argon2 task in
`authenticating`, kicks its exact ConnectionId, and requires the Operation
to wait through native reap without late activation. The snapshot gate
distinguishes normal final-save deletion from a runtime-successful delete
followed by SIGKILL before the next snapshot. These are process gates within
the strict chain, not separate full release runs.

The strict distribution builder creates a private digest file owned by UID
65532 and separate client token files. Each of the four isolated runtime
profiles runs MQTT smoke with management disabled, A-only, and details plus
operations enabled. Disabled mode must have no management port. B mode
performs real read, kick and offline delete against the packaged binary.
The full profile also runs the pinned Prometheus check on the A-only
instance, requiring authorized `up=1`, wrong-token `up=0` and
`moonbit_mqtt_broker_build_info=1`. Inventory explicitly checks
`libcrypto.so` because `ldd` does not list every `dlopen` dependency.
Keep `runtime-*-management.log` and `runtime-*-admin.log` alongside MQTT
runtime logs. Same HEAD, same artifact hashes, four profile PASS records
and the outermost exit code 0 are required. A-only and disabled coverage
must remain when B is added.

The full performance protocol and thresholds below remain required where applicable. Prefer a dedicated CI job after the behavior exists and there is a concrete performance risk or a formal candidate, not once per matrix ID. The current workflow does not invoke this script or upload its JSON/TSV/raw samples. Future integration must add safe artifact coverage, including the executable needed for complete hash verification. Until a suitable runner satisfies the measurement contract, the agent hands exact commands to the user. Keep short fixture checks distinct from formal measurement; handle fixture failure as described above. Historical management evidence is unchanged.

The separate `scripts/verify-management-admin-performance.sh` compares
the same Native binary and 32 MiB parent-cap configuration with B off
(A-only) and B on. Three paired rounds each warm for 10 seconds and
measure 60 seconds under QoS 0/1/2 traffic. B-on adds a 1 Hz scrape,
5 Hz detail pagination and one offline Session operation per second.
Each B-on round needs at least 90% of the B-off throughput; PING and QoS 1
PUBACK P99 must stay within the larger of twice baseline or baseline plus
20 ms. A further 60-second B overload fills query/cursor/command/Operation
pressure while holding 16 slow HTTP readers; every five-second window must
include a successful MQTT PING. Containers use 2 CPUs, 256 MiB and 64
processes. Preserve raw samples, fd counts and the threshold summary under
`.local/p1-03b-execution/performance-*`. Run this separately from
distribution soak so the two loads do not contaminate one another. The
earlier A-only performance evidence remains under
`.local/p1-03a-execution/`.

## P1-02 transport gate

The strict distribution chain reaches `scripts/verify-release.sh`, whose
`tests/integration/transports.sh` case starts TCP, TLS, WS and WSS in one
Broker. MQTT.js checks four-entry QoS 1 routing and TCP-to-WSS persistent
Session resumption. The same case checks that WS-enabled startup fails
cleanly when `libcrypto.so.3` or its required EVP symbols are unavailable,
while TCP-only validation still works. Native package tests cover bounded
Upgrade parsing, WebSocket frame boundaries, WSS with certificate
verification, and private TLS material capture. CI supplies the complete
functional and distribution record for the committed candidate; development
uses only focused checks.

## P1-01 strict durability gate

The committed-candidate release chain calls `durability_transports.sh` and
`durability_commit.sh` once from `verify-release.sh`. They exercise TCP,
TLS, WS and WSS, QoS 1/2 restart recovery, a held fsync with an independent
connection, and SIGKILL after a committed acknowledgement. Native tests cover
WAL format, tail repair, checkpoint failure points, coordinator ordering and
management B12. The distribution verifier additionally runs strict seed,
restart and B12 admin operations in each of the four runtime profiles using
the exported candidate binary, a non-root process, read-only root filesystem
and an independently writable persistent volume. Require
`runtime_base_strict`, `runtime_argon2_strict`, `runtime_tls_strict` and
`runtime_full_strict` to be `PASS` in the same `evidence.txt`.

With `RELEASE_SOAK=1`, the strict transport gate also runs the bounded
ten-minute mixed QoS 1/2 workload (default 20,000 publications, configurable
with `STRICT_SOAK_PUBLICATIONS`) and saves its JSON latency/receive counts.
The older stability workload retains its independent default of 100,000
publications. A default push CI run does not enable these extended workloads.
The fixed-disk paired off/snapshot/strict performance measurement has no
suitable GitHub-hosted runner; follow the remote manual command handoff for
the exact pushed candidate. Neither a default CI submission nor a short
development smoke establishes formal soak or hardware performance acceptance.

The remote `scripts/run-p1-01-performance.sh` is the fixed-hardware
measurement entry point. Set `PERF_EXPECTED_SHA` to the complete pushed SHA.
It runs three rotated paired rounds on the same pinned development image,
two CPUs, 512 MiB and independent Docker named data volumes. The built-in
global and per-IP rate policies are disabled equally in all three modes;
each round records its effective Broker arguments. Each round covers
low-rate, eight-publisher, 256 KiB payload, eight-recipient fanout, QoS 2,
and offline backlog scenarios; strict additionally has a paced checkpoint
window. It records ACK and QoS 2 PUBREC/PUBCOMP samples, traced fsync times,
WAL batch fill and bytes, CPU/RSS samples, volume bytes and measured restart
time with a retained-state probe. A formal run requires a second checkpoint
generation in each strict round and retains the test volumes for investigation.
A `PERF_QUICK=1` run is only fixture validation. Compare paired rounds on the
actual named storage and review latency and capacity against the target
deployment's budget; no universal P99 target is asserted by this project.
