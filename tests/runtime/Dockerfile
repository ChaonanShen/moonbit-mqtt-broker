# Test environments intentionally contain no MoonBit, compiler, or MQTT client.
FROM ubuntu:24.04 AS base
RUN apt-get update \
    && apt-get install --yes --no-install-recommends libgcc-s1 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /tmp
USER 65532:65532
ENTRYPOINT ["/artifact/broker"]

FROM base AS argon2
USER root
RUN apt-get update \
    && apt-get install --yes --no-install-recommends libargon2-1 \
    && rm -rf /var/lib/apt/lists/*
USER 65532:65532

FROM base AS tls
USER root
RUN apt-get update \
    && apt-get install --yes --no-install-recommends libssl3t64 \
    && rm -rf /var/lib/apt/lists/*
USER 65532:65532

FROM argon2 AS full
USER root
RUN apt-get update \
    && apt-get install --yes --no-install-recommends libssl3t64 \
    && rm -rf /var/lib/apt/lists/*
USER 65532:65532
