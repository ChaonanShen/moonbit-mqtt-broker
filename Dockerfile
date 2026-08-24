FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
      build-essential ca-certificates curl git mosquitto-clients strace xz-utils \
    && rm -rf /var/lib/apt/lists/*

ARG NODE_VERSION="22.23.1"
RUN curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
    && tar -xJf "node-v${NODE_VERSION}-linux-x64.tar.xz" -C /usr/local --strip-components=1 \
    && rm "node-v${NODE_VERSION}-linux-x64.tar.xz" \
    && node --version \
    && npm --version

ENV MOONBIT_INSTALL_VERSION="0.10.8+8606a5800"
RUN curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash

ENV PATH="/root/.moon/bin:${PATH}"
RUN moon update

WORKDIR /workspace
ENTRYPOINT ["moon"]
