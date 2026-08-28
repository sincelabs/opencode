# syntax=docker/dockerfile:1
#
# Self-hosted opencode server, built from this repository.
#
# The web UI (packages/app) is only embedded into the binary by
# packages/opencode/script/build.ts -- running the CLI straight from source
# makes the server fall back to proxying https://app.opencode.ai instead. So we
# compile a real binary here and the resulting image serves your fork's UI.
#
#   docker build -f deploy/coolify/Dockerfile -t opencode-server .

ARG BUN_VERSION=1.3.14

# ---------------------------------------------------------------- build stage
FROM oven/bun:${BUN_VERSION}-debian AS build

# node-gyp is invoked by native postinstall scripts (node-pty, tree-sitter) and
# needs Node >= 22 plus a toolchain; python3-setuptools covers distutils.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       build-essential ca-certificates curl git python3 python3-setuptools unzip xz-utils \
  && curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
  && apt-get install -y --no-install-recommends nodejs \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# packages/script derives the version and channel from `git branch --show-current`
# and the npm registry when these are unset, and .dockerignore strips .git --
# so pin them explicitly instead of letting the build reach for either.
ARG OPENCODE_CHANNEL=selfhost
ARG OPENCODE_VERSION=0.0.0-selfhost
ENV OPENCODE_CHANNEL=${OPENCODE_CHANNEL} \
    OPENCODE_VERSION=${OPENCODE_VERSION}

COPY . .

RUN bun install --frozen-lockfile

# --single builds only the current platform/arch target.
RUN bun run ./packages/opencode/script/build.ts --single \
  && mkdir -p /out \
  && cp -r packages/opencode/dist/*/bin/. /out/ \
  && test -x /out/opencode

# -------------------------------------------------------------- runtime stage
FROM debian:trixie-slim AS runtime

# ripgrep backs the grep tool; git/openssh let the agent work with real repos.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       ca-certificates curl git libgcc-s1 libstdc++6 openssh-client ripgrep tini \
  && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/ /usr/local/bin/

# Everything opencode persists lives under /data (see packages/core/src/global.ts:
# auth credentials, session database, logs, cached models). /workspace is where
# your projects go. Both need to be volumes or you lose them on redeploy.
ENV HOME=/data \
    XDG_DATA_HOME=/data/share \
    XDG_CONFIG_HOME=/data/config \
    XDG_STATE_HOME=/data/state \
    XDG_CACHE_HOME=/data/cache \
    OPENCODE_DISABLE_AUTOUPDATE=1 \
    OPENCODE_PORT=4096 \
    OPENCODE_HOSTNAME=0.0.0.0

RUN mkdir -p /data /workspace
WORKDIR /workspace

EXPOSE 4096

# /site.webmanifest is one of the few paths that bypasses basic auth
# (see packages/opencode/src/server/shared/public-ui.ts), so it works as a
# health probe whether or not OPENCODE_SERVER_PASSWORD is set.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${OPENCODE_PORT}/site.webmanifest" > /dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["sh", "-c", "exec opencode serve --hostname \"$OPENCODE_HOSTNAME\" --port \"$OPENCODE_PORT\" ${OPENCODE_CORS_ORIGIN:+--cors \"$OPENCODE_CORS_ORIGIN\"}"]
