#!/bin/bash
#
# Evict clean Linux page cache for PostgreSQL data files when the container's
# cgroup file cache grows past a threshold.
#
# Why this exists
# ---------------
# PostgreSQL reads heap/index files through the kernel's buffered I/O. A large
# sequential scan, a big sort, or pgBackRest reading the whole data directory
# leaves those pages in the kernel page cache. Linux keeps clean page cache
# until something creates memory pressure or someone explicitly evicts it.
# Railway bills the container's cgroup memory.current (which includes that
# cache, sampled every 30s), so a 10 GB page cache looks like a 10 GB leak even
# though PostgreSQL's own RSS is small.
#
# vmtouch -e uses posix_fadvise(POSIX_FADV_DONTNEED) on the given files. It
# only drops *clean* pages. Dirty pages are left for PostgreSQL's checkpointer
# and the kernel writeback. It does not touch PostgreSQL shared_buffers or any
# anonymous memory.
#
# This script is intentionally conservative:
#   - only runs when inactive_file cache is above CACHE_RECLAIM_THRESHOLD_MB;
#   - waits CACHE_RECLAIM_MIN_INTERVAL_SECONDS between trims;
#   - skips while a long query is active;
#   - skips while pgBackRest is running;
#   - runs vmtouch at low CPU/I/O priority with a timeout.

set -uo pipefail

PGDATA="${PGDATA:-/var/lib/postgresql/data}"
PGPORT="${PGPORT:-5432}"

CACHE_RECLAIM_INTERVAL_SECONDS="${CACHE_RECLAIM_INTERVAL_SECONDS:-60}"
CACHE_RECLAIM_THRESHOLD_MB="${CACHE_RECLAIM_THRESHOLD_MB:-2048}"
CACHE_RECLAIM_MIN_INTERVAL_SECONDS="${CACHE_RECLAIM_MIN_INTERVAL_SECONDS:-900}"
CACHE_RECLAIM_TARGETS="${CACHE_RECLAIM_TARGETS:-${PGDATA}/base,${PGDATA}/global,${PGDATA}/pg_tblspc,${PGDATA}/pg_wal,${PGDATA}/pgbackrest-spool}"
CACHE_RECLAIM_SKIP_LONG_QUERIES="${CACHE_RECLAIM_SKIP_LONG_QUERIES:-true}"
CACHE_RECLAIM_LONG_QUERY_SECONDS="${CACHE_RECLAIM_LONG_QUERY_SECONDS:-30}"
CACHE_RECLAIM_SKIP_BACKUP="${CACHE_RECLAIM_SKIP_BACKUP:-true}"
CACHE_RECLAIM_TIMEOUT_SECONDS="${CACHE_RECLAIM_TIMEOUT_SECONDS:-300}"
CACHE_RECLAIM_DRY_RUN="${CACHE_RECLAIM_DRY_RUN:-false}"

log() {
  printf '%s pg-cache-reclaim: %s\n' "$(date -u +%FT%TZ)" "$*"
}

is_uint() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

# Accept only whole numbers; a typo must not turn the reclaimer into a busy
# loop or a negative threshold.
if ! is_uint "$CACHE_RECLAIM_INTERVAL_SECONDS" || [ "$CACHE_RECLAIM_INTERVAL_SECONDS" -lt 10 ]; then
  log "invalid CACHE_RECLAIM_INTERVAL_SECONDS='${CACHE_RECLAIM_INTERVAL_SECONDS}', using 60"
  CACHE_RECLAIM_INTERVAL_SECONDS=60
fi
if ! is_uint "$CACHE_RECLAIM_THRESHOLD_MB"; then
  log "invalid CACHE_RECLAIM_THRESHOLD_MB='${CACHE_RECLAIM_THRESHOLD_MB}', using 2048"
  CACHE_RECLAIM_THRESHOLD_MB=2048
fi
if ! is_uint "$CACHE_RECLAIM_MIN_INTERVAL_SECONDS"; then
  log "invalid CACHE_RECLAIM_MIN_INTERVAL_SECONDS='${CACHE_RECLAIM_MIN_INTERVAL_SECONDS}', using 900"
  CACHE_RECLAIM_MIN_INTERVAL_SECONDS=900
fi
if ! is_uint "$CACHE_RECLAIM_LONG_QUERY_SECONDS"; then
  CACHE_RECLAIM_LONG_QUERY_SECONDS=30
fi
if ! is_uint "$CACHE_RECLAIM_TIMEOUT_SECONDS" || [ "$CACHE_RECLAIM_TIMEOUT_SECONDS" -lt 10 ]; then
  CACHE_RECLAIM_TIMEOUT_SECONDS=300
fi

MEMORY_STAT_FILE=""
if [ -r /sys/fs/cgroup/memory.stat ]; then
  MEMORY_STAT_FILE=/sys/fs/cgroup/memory.stat
elif [ -r /sys/fs/cgroup/memory/memory.stat ]; then
  MEMORY_STAT_FILE=/sys/fs/cgroup/memory/memory.stat
fi

memory_key() {
  local key="$1" value=""
  [ -n "$MEMORY_STAT_FILE" ] || { echo 0; return; }
  value=$(awk -v k="$key" '$1 == k { print $2; found=1; exit } END { if (!found) print 0 }' "$MEMORY_STAT_FILE" 2>/dev/null)
  echo "${value:-0}"
}

has_memory_key() {
  local key="$1"
  [ -n "$MEMORY_STAT_FILE" ] || return 1
  grep -q "^${key} " "$MEMORY_STAT_FILE" 2>/dev/null
}

memory_current() {
  if [ -r /sys/fs/cgroup/memory.current ]; then
    cat /sys/fs/cgroup/memory.current 2>/dev/null || echo 0
  elif [ -r /sys/fs/cgroup/memory/memory.usage_in_bytes ]; then
    cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null || echo 0
  else
    echo 0
  fi
}

memory_max() {
  local value=""
  if [ -r /sys/fs/cgroup/memory.max ]; then
    value=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
  elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
    value=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
  fi
  echo "${value:-max}"
}

mb() {
  local bytes="${1:-0}"
  [ "$bytes" = "max" ] && { echo "max"; return; }
  is_uint "$bytes" || { echo "0"; return; }
  echo $((bytes / 1024 / 1024))
}

wait_for_postgres() {
  local announced=0
  while ! pg_isready -q -h /var/run/postgresql -p "$PGPORT" -U postgres -d postgres >/dev/null 2>&1; do
    if [ "$announced" -eq 0 ]; then
      log "waiting for PostgreSQL on port ${PGPORT} before enabling cache trims"
      announced=1
    fi
    sleep 10
  done
}

long_query_active() {
  [ "$CACHE_RECLAIM_SKIP_LONG_QUERIES" = "true" ] || return 1

  local count
  count=$(psql -X -q -A -t \
    -h /var/run/postgresql -p "$PGPORT" -U postgres -d postgres \
    -v ON_ERROR_STOP=1 \
    -c "SELECT count(*) FROM pg_stat_activity
         WHERE state = 'active'
           AND pid <> pg_backend_pid()
           AND query_start IS NOT NULL
           AND now() - query_start > interval '${CACHE_RECLAIM_LONG_QUERY_SECONDS} seconds';" \
    2>/dev/null) || return 1

  count="${count//[[:space:]]/}"
  is_uint "$count" || return 1
  [ "$count" -gt 0 ]
}

backup_running() {
  [ "$CACHE_RECLAIM_SKIP_BACKUP" = "true" ] || return 1
  pgrep -f '[p]gbackrest' >/dev/null 2>&1
}

build_targets() {
  TARGETS=()
  local item trimmed
  local -a items=()
  IFS=',' read -r -a items <<< "$CACHE_RECLAIM_TARGETS"
  for item in "${items[@]}"; do
    # trim whitespace
    trimmed="${item#"${item%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [ -n "$trimmed" ] || continue
    if [ -d "$trimmed" ]; then
      TARGETS+=("$trimmed")
    fi
  done
}

reclaim_once() {
  local file_before="$1"
  local file_before_mb current_before_mb max_human anon_before_mb inactive_before_mb
  file_before_mb=$(mb "$file_before")
  current_before_mb=$(mb "$(memory_current)")
  anon_before_mb=$(mb "$(memory_key anon)")
  inactive_before_mb=$(mb "$(memory_key inactive_file)")
  max_human=$(memory_max)
  [ "$max_human" != "max" ] && max_human="$(mb "$max_human")MB"

  if ! command -v vmtouch >/dev/null 2>&1; then
    log "vmtouch not found; cannot trim page cache"
    return 1
  fi

  build_targets
  if [ "${#TARGETS[@]}" -eq 0 ]; then
    log "no existing CACHE_RECLAIM_TARGETS (${CACHE_RECLAIM_TARGETS}); nothing to trim"
    return 1
  fi

  log "trimming: file=${file_before_mb}MB inactive=${inactive_before_mb}MB anon=${anon_before_mb}MB current=${current_before_mb}MB limit=${max_human:-max}"
  if [ "$CACHE_RECLAIM_DRY_RUN" = "true" ]; then
    log "dry run: would run vmtouch -e -f ${TARGETS[*]}"
    return 0
  fi

  local -a cmd=(vmtouch -e -f "${TARGETS[@]}")
  if command -v ionice >/dev/null 2>&1; then
    cmd=(ionice -c 3 "${cmd[@]}")
  fi
  if command -v nice >/dev/null 2>&1; then
    cmd=(nice -n 19 "${cmd[@]}")
  fi
  if command -v timeout >/dev/null 2>&1; then
    cmd=(timeout "$CACHE_RECLAIM_TIMEOUT_SECONDS" "${cmd[@]}")
  fi

  local output_file="/tmp/pg-cache-reclaim.vmtouch.$$"
  "${cmd[@]}" >"$output_file" 2>&1
  local rc=$?

  local file_after current_after
  file_after=$(memory_key file)
  current_after=$(memory_current)
  log "trim finished rc=${rc}: file=${file_before_mb}MB -> $(mb "$file_after")MB, current=${current_before_mb}MB -> $(mb "$current_after")MB"

  if [ "$rc" -ne 0 ]; then
    log "vmtouch output: $(tail -n 3 "$output_file" 2>/dev/null | tr '\n' ' ')"
  fi
  rm -f "$output_file" 2>/dev/null || true

  # rc=124 means the timeout hit; the next pass can finish the job.
  [ "$rc" -eq 0 ] || [ "$rc" -eq 124 ]
}

log "starting (interval=${CACHE_RECLAIM_INTERVAL_SECONDS}s threshold=${CACHE_RECLAIM_THRESHOLD_MB}MB inactive_file min_interval=${CACHE_RECLAIM_MIN_INTERVAL_SECONDS}s targets=${CACHE_RECLAIM_TARGETS})"

wait_for_postgres

THRESHOLD_BYTES=$((CACHE_RECLAIM_THRESHOLD_MB * 1024 * 1024))
LAST_RECLAIM=0

while true; do
  sleep "$CACHE_RECLAIM_INTERVAL_SECONDS"

  pg_isready -q -h /var/run/postgresql -p "$PGPORT" -U postgres -d postgres >/dev/null 2>&1 || continue

  FILE_BYTES=$(memory_key file)
  is_uint "$FILE_BYTES" || continue

  # Trigger on inactive_file, not total file cache: inactive pages are the
  # cold/reclaimable part. If the kernel reports file cache high but
  # inactive_file is low, that cache is hot and evicting it would only hurt
  # latency. Fall back to total file cache on kernels without inactive_file.
  if has_memory_key inactive_file; then
    RECLAIMABLE_BYTES=$(memory_key inactive_file)
  else
    RECLAIMABLE_BYTES=$FILE_BYTES
  fi
  is_uint "$RECLAIMABLE_BYTES" || continue
  [ "$RECLAIMABLE_BYTES" -ge "$THRESHOLD_BYTES" ] || continue

  NOW=$(date +%s)
  if [ $((NOW - LAST_RECLAIM)) -lt "$CACHE_RECLAIM_MIN_INTERVAL_SECONDS" ]; then
    continue
  fi
  if long_query_active; then
    log "skipping: a query has been active for more than ${CACHE_RECLAIM_LONG_QUERY_SECONDS}s"
    continue
  fi
  if backup_running; then
    log "skipping: pgBackRest is running"
    continue
  fi

  # Record the attempt even when vmtouch fails or times out. A persistent
  # failure (e.g. a filesystem that ignores fadvise) must not turn into a
  # retry every CACHE_RECLAIM_INTERVAL_SECONDS; the min-interval backoff is
  # the guardrail.
  reclaim_once "$FILE_BYTES" || true
  LAST_RECLAIM=$NOW
done
