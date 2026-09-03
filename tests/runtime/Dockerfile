# Test environments intentionally contain no MoonBit, compiler, or MQTT client.
FROM ubuntu:24.04 AS base
RUN apt-get update \
    && apt-get install --yes --no-install-recommends libgcc-s1 \
    && rm -rf /var/lib/apt/lists/*
# Ubuntu coreutils needs libcrypto from the OpenSSL package. Remove only the
# optional loader entry points, so negative cases do not break unrelated tools.
RUN rm -f /usr/lib/x86_64-linux-gnu/libssl.so \
          /usr/lib/x86_64-linux-gnu/libssl.so.3 \
          /usr/lib/x86_64-linux-gnu/libssl.so.1.1 \
          /usr/lib/x86_64-linux-gnu/libargon2.so \
          /usr/lib/x86_64-linux-gnu/libargon2.so.1 \
    && ldconfig
WORKDIR /tmp
USER 65532:65532
ENTRYPOINT ["/artifact/broker"]

FROM base AS argon2
USER root
RUN apt-get update \
    && apt-get install --yes --reinstall --no-install-recommends libargon2-1 \
    && rm -rf /var/lib/apt/lists/*
USER 65532:65532

FROM base AS tls
USER root
RUN apt-get update \
    && apt-get install --yes --reinstall --no-install-recommends libssl3t64 \
    && rm -rf /var/lib/apt/lists/*
USER 65532:65532

FROM argon2 AS full
USER root
RUN apt-get update \
    && apt-get install --yes --reinstall --no-install-recommends libssl3t64 \
    && rm -rf /var/lib/apt/lists/*
USER 65532:65532
