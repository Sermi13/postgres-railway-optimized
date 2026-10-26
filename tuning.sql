-- Tuning inicial para PostgreSQL 17/18 no Railway.
--
-- Ajuste os valores ao tamanho do banco e ao limite de memória do serviço.
-- Execute como superuser:
--   psql -U postgres -d postgres -f tuning.sql
--
-- shared_buffers e max_connections exigem restart do PostgreSQL para valer.
-- Os demais parâmetros entram com SELECT pg_reload_conf().
--
-- ATENÇÃO: max_connections = 4000 é um teto, não uma meta. Cada backend
-- ocioso custa alguns MB de RAM. 4000 conexões diretas podem consumir dezenas
-- de GB. O uso recomendado é PgBouncer na frente, com um pool pequeno de
-- conexões de servidor; o teto de 4000 só evita "too many clients" em picos.
--
-- Se você preferir não usar ALTER SYSTEM, use o Custom Start Command descrito
-- no README; o efeito é o mesmo e não grava nada no volume.

ALTER SYSTEM SET shared_buffers = '1GB';
ALTER SYSTEM SET max_connections = '4000';
ALTER SYSTEM SET effective_cache_size = '2GB';
ALTER SYSTEM SET work_mem = '8MB';
ALTER SYSTEM SET maintenance_work_mem = '128MB';
ALTER SYSTEM SET temp_buffers = '16MB';
ALTER SYSTEM SET idle_in_transaction_session_timeout = '60s';
ALTER SYSTEM SET log_temp_files = 1024;

-- Opcional: só habilite se o app reconecta sozinho ou se você usa PgBouncer.
-- Sem pooler, isso pode derrubar conexões ociosas de aplicações antigas.
-- ALTER SYSTEM SET idle_session_timeout = '15min';

SELECT pg_reload_conf();

-- Depois do restart, confira:
--   SHOW shared_buffers;
--   SHOW max_connections;
--   SHOW effective_cache_size;
--   SHOW work_mem;
