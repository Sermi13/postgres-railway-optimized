#!/bin/bash
#
# Read-only memory diagnostic for the Railway PostgreSQL container.
# Run inside the service shell:
#   /usr/local/bin/diagnose-memory.sh
#
# It answers the first question before changing anything:
# is the memory anonymous (PostgreSQL processes) or file cache (kernel)?

set -uo pipefail

PGDATA="${PGDATA:-/var/lib/postgresql/data}"
PGPORT="${PGPORT:-5432}"

section() {
  printf '\n===== %s =====\n' "$*"
}

mb() {
  local bytes="${1:-0}"
  case "$bytes" in
    ''|*[!0-9]*) echo "?"; return ;;
  esac
  echo "$((bytes / 1024 / 1024)) MB"
}

section "cgroup limits"
for f in memory.current memory.max memory.high memory.peak; do
  if [ -r "/sys/fs/cgroup/$f" ]; then
    v=$(cat "/sys/fs/cgroup/$f" 2>/dev/null)
    if [ "$v" != "max" ]; then
      printf '%-16s %s (%s)\n' "$f" "$v" "$(mb "$v")"
    else
      printf '%-16s %s\n' "$f" "$v"
    fi
  fi
done

section "cgroup memory.stat (the important part)"
for f in /sys/fs/cgroup/memory.stat /sys/fs/cgroup/memory/memory.stat; do
  [ -r "$f" ] || continue
  echo "source: $f"
  awk '
    $1 == "anon"          { printf "%-18s %12d  (%s)\n", $1, $2, int($2/1048576) " MB" }
    $1 == "file"          { printf "%-18s %12d  (%s)\n", $1, $2, int($2/1048576) " MB" }
    $1 == "active_file"   { printf "%-18s %12d  (%s)\n", $1, $2, int($2/1048576) " MB" }
    $1 == "inactive_file" { printf "%-18s %12d  (%s)\n", $1, $2, int($2/1048576) " MB" }
    $1 == "shmem"         { printf "%-18s %12d  (%s)\n", $1, $2, int($2/1048576) " MB" }
    $1 == "kernel"        { printf "%-18s %12d  (%s)\n", $1, $2, int($2/1048576) " MB" }
  ' "$f"
done
cat <<'EOF'

Interpretation:
  anon  high  -> PostgreSQL processes: connections, work_mem, temp tables.
  file  high  -> Linux page cache from reads/backups. This is what the
                 reclaimer targets. inactive_file is the reclaimable part.
EOF

section "top processes by RSS"
ps -eo pid,ppid,rss,pcpu,stat,comm,args --sort=-rss 2>/dev/null | head -n 20

section "top PostgreSQL backends (approximate RSS, not exact)"
ps -eo pid,rss,stat,args --sort=-rss 2>/dev/null | grep '[p]ostgres' | head -n 15

section "PostgreSQL settings"
psql -X -h /var/run/postgresql -p "$PGPORT" -U postgres -d postgres -P pager=off <<'SQL' 2>&1 || true
SELECT name, setting, unit
FROM pg_settings
WHERE name IN (
  'max_connections',
  'shared_buffers',
  'work_mem',
  'maintenance_work_mem',
  'autovacuum_work_mem',
  'temp_buffers',
  'effective_cache_size',
  'idle_session_timeout',
  'idle_in_transaction_session_timeout',
  'max_parallel_workers_per_gather',
  'max_worker_processes',
  'log_temp_files'
)
ORDER BY name;
SQL

section "connections by state"
psql -X -h /var/run/postgresql -p "$PGPORT" -U postgres -d postgres -P pager=off <<'SQL' 2>&1 || true
SELECT state, count(*)
FROM pg_stat_activity
GROUP BY state
ORDER BY count(*) DESC;
SQL

section "queries active for more than 5 seconds"
psql -X -h /var/run/postgresql -p "$PGPORT" -U postgres -d postgres -P pager=off <<'SQL' 2>&1 || true
SELECT pid,
       now() - query_start AS age,
       state,
       wait_event_type,
       wait_event,
       left(query, 120) AS query
FROM pg_stat_activity
WHERE state = 'active'
  AND pid <> pg_backend_pid()
  AND query_start IS NOT NULL
  AND now() - query_start > interval '5 seconds'
ORDER BY age DESC;
SQL

section "database sizes"
psql -X -h /var/run/postgresql -p "$PGPORT" -U postgres -d postgres -P pager=off <<'SQL' 2>&1 || true
SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size
FROM pg_database
ORDER BY pg_database_size(datname) DESC;
SQL

section "I/O and temp file totals since stats reset"
psql -X -h /var/run/postgresql -p "$PGPORT" -U postgres -d postgres -P pager=off <<'SQL' 2>&1 || true
SELECT datname,
       temp_files,
       pg_size_pretty(temp_bytes) AS temp_bytes,
       blks_read,
       blks_hit,
       round(100.0 * blks_hit / nullif(blks_hit + blks_read, 0), 2) AS cache_hit_pct
FROM pg_stat_database
WHERE datname IS NOT NULL
ORDER BY temp_bytes DESC;
SQL

section "pg_stat_io (PostgreSQL 16+)"
psql -X -h /var/run/postgresql -p "$PGPORT" -U postgres -d postgres -P pager=off <<'SQL' 2>&1 || true
SELECT backend_type,
       object,
       context,
       reads,
       pg_size_pretty(
         COALESCE(
           (to_jsonb(io) ->> 'read_bytes')::numeric,
           reads * current_setting('block_size')::numeric,
           0
         )::bigint
       ) AS approx_read_bytes,
       writes,
       pg_size_pretty(
         COALESCE(
           (to_jsonb(io) ->> 'write_bytes')::numeric,
           writes * current_setting('block_size')::numeric,
           0
         )::bigint
       ) AS approx_write_bytes
FROM pg_stat_io AS io
WHERE reads > 0 OR writes > 0
ORDER BY reads DESC NULLS LAST
LIMIT 15;
SQL

section "top statements by shared blocks read and temp writes"
psql -X -h /var/run/postgresql -p "$PGPORT" -U postgres -d postgres -P pager=off <<'SQL' 2>&1 || true
SELECT to_regclass('public.pg_stat_statements') IS NOT NULL AS has_pgss \gset
\if :has_pgss
SELECT calls,
       shared_blks_read,
       temp_blks_read,
       temp_blks_written,
       left(query, 140) AS query
FROM pg_stat_statements
ORDER BY (shared_blks_read + temp_blks_written) DESC
LIMIT 10;
\else
\echo 'pg_stat_statements is not installed in this database (CREATE EXTENSION pg_stat_statements;)'
\endif
SQL

section "volume usage"
df -h "$PGDATA" 2>/dev/null || true

section "done"
