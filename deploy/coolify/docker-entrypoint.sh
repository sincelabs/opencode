#!/bin/sh
# With no arguments, start the server the way a hosted deployment wants it.
# With arguments, forward them to the CLI so `docker run <image> --version` and
# `docker run <image> run "..."` behave the way you'd expect.
set -e

if [ "$#" -gt 0 ]; then
  exec opencode "$@"
fi

if [ -z "$OPENCODE_SERVER_PASSWORD" ]; then
  echo "warning: OPENCODE_SERVER_PASSWORD is empty -- this server accepts anyone who can reach it." >&2
fi

set -- serve --hostname "${OPENCODE_HOSTNAME:-0.0.0.0}" --port "${OPENCODE_PORT:-4096}"
if [ -n "$OPENCODE_CORS_ORIGIN" ]; then
  set -- "$@" --cors "$OPENCODE_CORS_ORIGIN"
fi

exec opencode "$@"
