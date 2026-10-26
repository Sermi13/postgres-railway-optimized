#!/bin/bash
#
# Starts the optional page-cache reclaimer, then replaces this shell with the
# original Railway postgres-ssl wrapper.
#
# Why exec:
#   The base wrapper is carefully built around tini -g: tini is PID 1, the
#   wrapper is its child, and docker-entrypoint/postgres run in the wrapper's
#   process group. Exec'ing the base wrapper keeps that exact process tree, so
#   SIGINT (STOPSIGNAL) still reaches postgres and the wrapper's own trap still
#   works.
#
# Why setsid for the reclaimer:
#   If the reclaimer stayed in the container's process group, tini -g would
#   deliver SIGINT to it during a normal stop. It is harmless if it dies, but
#   keeping it in a separate session avoids interfering with the database's
#   shutdown path. The container runtime kills it when the container exits.

set -uo pipefail

log() {
  printf '%s entrypoint: %s\n' "$(date -u +%FT%TZ)" "$*"
}

case "${CACHE_RECLAIM_ENABLED:-true}" in
  true|TRUE|1|yes|YES)
    if command -v setsid >/dev/null 2>&1; then
      setsid /usr/local/bin/pg-cache-reclaim.sh &
    else
      /usr/local/bin/pg-cache-reclaim.sh &
    fi
    log "page-cache reclaimer started (pid $!)"
    ;;
  *)
    log "page-cache reclaimer disabled by CACHE_RECLAIM_ENABLED"
    ;;
esac

exec /usr/local/bin/wrapper.sh "$@"
