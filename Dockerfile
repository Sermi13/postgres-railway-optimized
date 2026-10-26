# PostgreSQL 17 (Railway template) + page-cache reclaimer.
#
# The base image is the exact image Railway's Postgres template uses:
#   ghcr.io/railwayapp-templates/postgres-ssl:17
#
# We keep its entrypoint/wrapper behavior and only add:
#   - vmtouch: userspace tool that calls posix_fadvise(POSIX_FADV_DONTNEED)
#     to evict clean page cache for the data files.
#   - a small supervisor that starts the reclaimer in the background before
#     handing control to the original /usr/local/bin/wrapper.sh.
#
# No PostgreSQL data files, config files, or entrypoint logic are replaced.

FROM ghcr.io/railwayapp-templates/postgres-ssl:17

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends vmtouch \
    && rm -rf /var/lib/apt/lists/*

COPY --chmod=755 pg-cache-reclaim.sh      /usr/local/bin/pg-cache-reclaim.sh
COPY --chmod=755 entrypoint-wrapper.sh    /usr/local/bin/entrypoint-wrapper.sh
COPY --chmod=755 diagnose-memory.sh       /usr/local/bin/diagnose-memory.sh

# Same STOPSIGNAL as the base image (SIGINT). Kept explicit so a future
# base-image change cannot silently turn graceful stops into SIGKILLs.
STOPSIGNAL SIGINT

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/entrypoint-wrapper.sh"]
# max_connections is a command-line setting so it wins over the template's
# max_connections=500 in postgresql.auto.conf. 4000 is a ceiling, not a target:
# direct connections are expensive; put PgBouncer in front for real workloads.
CMD ["postgres", "-p", "5432", "-c", "listen_addresses=*", "-c", "max_connections=4000"]
