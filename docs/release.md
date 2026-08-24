# Release and provenance

Version 0.1.0 is built and accepted only as Linux x86_64 Native in the pinned
Ubuntu 24.04 container. The base image resolves to
`ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517`.
The image installs Moon CLI `0.1.20260814` (`a2de5b2`), Moon compiler
`0.10.8+8606a5800`, Moon runner `0.1.20260814`, Node.js `22.23.1`, npm
`10.9.8`, and Ubuntu Mosquitto `2.0.18-1build3`.

Run the reversible release gates from a clean checkout:

```bash
docker build --platform linux/amd64 -t moonbit-mqtt-broker-dev .
scripts/m5-verify-docker.sh
scripts/check-package.sh
```

The final candidate requires three successful M5 verifier runs against the
same commit and image, one `M5_SOAK=1` extended run, and a clean
`scripts/m5-release-check.sh`. The check script is read-only: it validates the
commit, origin, version, tag state, verifier record, archive metadata, and an
optional read-only credential mount. It never invokes publish, push, or a
release API.

Publishing is deliberately manual. Confirm the release commit, namespace
`ChaonanShen/moonbit-mqtt-broker`, version `0.1.0`, package SHA-256, image ID,
and credential mount. Then run `moon publish --frozen --dry-run`, review its
namespace/version/files, and run exactly one real `moon publish --frozen` only
with explicit maintainer authorization. Verify a fresh registry consumer before
pushing the annotated `v0.1.0` tag and creating the GitHub release. Never force
a tag, overwrite a published version, copy credentials into the repository, or
retry an uncertain publish before a read-only registry query.

Disk V1 is checksummed latest-committed snapshot durability, not a WAL or
zero-loss boundary. A failed pre-publish gate stops the release. If publishing
succeeds but registry consumption fails, do not claim completion or mutate the
published artifact; diagnose and, if replacement is prohibited, prepare a new
SemVer patch through the complete gate.
