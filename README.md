# PostgreSQL 17 e 18 na Railway: controle de RAM / page cache

Imagens disponíveis:

| Versão | Imagem |
|---|---|
| PostgreSQL 17 | `ghcr.io/sermi13/postgres-railway-optimized:17` |
| PostgreSQL 18 | `ghcr.io/sermi13/postgres-railway-optimized:18` |

Solução para o caso:

- imagem base `ghcr.io/railwayapp-templates/postgres-ssl:17` ou `:18`
- depois de uma query grande (ou de um backup), o uso de RAM sobe para 10 GB+
- o consumo não cai sozinho; só volta ao normal com restart/redeploy
- a Railway cobra memória por uso, e o page cache do Linux entra na conta

O objetivo é **não depender de restart** para liberar a memória e manter o
container em um patamar previsível.

---

## 1. O que está acontecendo

Não é, na maioria dos casos, vazamento do PostgreSQL.

O PostgreSQL lê os arquivos de dados pelo I/O buferizado do Linux. Uma query
que faz sequential scan, um `ORDER BY`/hash grande, um `COPY` ou o pgBackRest
lendo o banco inteiro deixam essas páginas no **page cache** do kernel. O Linux
mantém page cache limpo em memória até:

1. alguém precisar de memória (pressão de memória), ou
2. alguém evictar explicitamente (`posix_fadvise(..., POSIX_FADV_DONTNEED)`).

Como o container da Railway normalmente tem limite de memória alto (ou
ilimitado), não existe pressão. O cache fica parado em 6, 8, 10 GB. O
`shared_buffers` do template é só 128 MB, então o PostgreSQL foi desenhado para
usar justamente esse cache do sistema operacional.

A Railway confirmou em um caso público que a memória cobrada é o
`cgroup memory.current` **mais swap**, amostrado a cada 30 s, sem descontar
`inactive_file`:

- https://station.railway.com/questions/railway-postgres-pitr-backup-leaves-6-gb-e762df27

Ou seja: page cache limpo conta na fatura, mesmo sendo reciclável.

### Como confirmar no seu container

Rode dentro do serviço:

```bash
/usr/local/bin/diagnose-memory.sh
```

O bloco decisivo é o `memory.stat`:

```text
anon           1.2 GB   -> memória dos processos PostgreSQL
file           9.8 GB   -> page cache do kernel
inactive_file  9.4 GB   -> parte reciclável do cache
```

- `file`/`inactive_file` alto: é page cache. A solução deste repositório ataca
  isso.
- `anon` alto: são conexões/backends, `work_mem`, tabelas temporárias ou
  vazamento. Aí a solução é tuning de conexões/`work_mem` e investigação das
  queries; o reclaimer não resolve.

---

## 2. Solução proposta em 3 camadas

### Camada 1 — limite de memória na Railway (rede de segurança)

A própria Railway recomenda limitar a memória do serviço. O kernel passa a
reciclar page cache sozinho quando o container se aproxima do limite.

- Em **Service → Settings → Deploy → Replica Limits**, defina um limite.
- Ponto de partida: **1,5x a 2x o pico de `anon` + `shared_buffers`**.
- Exemplo do caso da Railway: uso real ~1 GB, limite de 4 GB.
- Não coloque o limite igual ao baseline: queries grandes podem estourar e
  sofrer OOM.

Isso sozinho já evita os 10 GB, mas o cache pode ficar “encostado” no limite.
Para efetivamente **baixar** o uso, entra a camada 2.

### Camada 2 — trim ativo do page cache (imagem custom)

O `vmtouch -e` chama `posix_fadvise(POSIX_FADV_DONTNEED)` nos arquivos de dados.
Ele remove páginas **limpas** do cache; páginas sujas continuam para o
checkpointer/writeback. Não mexe no `shared_buffers` nem em memória anônima.

A imagem deste repositório:

- parte da mesma imagem do template;
- instala `vmtouch`;
- inicia um reclaimer em background antes de entregar o controle ao
  `wrapper.sh` original;
- a cada `CACHE_RECLAIM_INTERVAL_SECONDS` verifica o `memory.stat`;
- se `inactive_file` (a parte fria/reciclável do cache) passar de
  `CACHE_RECLAIM_THRESHOLD_MB`, roda `vmtouch -e` em `base`, `global`,
  `pg_tblspc`, `pg_wal` e no spool do pgBackRest;
- respeita intervalo mínimo entre trims;
- pula se houver query ativa há mais de N segundos;
- pula se o pgBackRest estiver rodando;
- roda com `nice`/`ionice` e timeout.

Não há restart do PostgreSQL. O `wrapper.sh` e o `docker-entrypoint.sh`
originais continuam sendo usados, então SSL, pgBackRest, PITR, upgrade de
major, locks de volume etc. continuam iguais.

### Camada 3 — tuning do PostgreSQL (evita gerar tanto cache)

O template, em volume já inicializado, escreve `max_connections = 500` no
`postgresql.auto.conf`. A imagem deste repositório sobrescreve isso para
**4000** via linha de comando (`-c max_connections=4000`), que tem precedência
sobre o `auto.conf`.

**Atenção:** 4000 é um teto, não uma meta. Cada backend ocioso custa alguns MB
de RAM; 4000 conexões diretas podem consumir dezenas de GB e estourar um
container de 4 GB. O desenho recomendado é **PgBouncer na frente**, com um pool
pequeno de conexões de servidor (100–200), e o teto de 4000 apenas para evitar
`too many clients` em picos. Se o app abre conexões diretas sem pooler, reduza
esse valor ou aumente bastante o limite de memória.

Configuração inicial sugerida (ajuste ao seu caso):

| Parâmetro | Sugestão | Observação |
|---|---:|---|
| `max_connections` | 4000 | teto; use PgBouncer com pool de 100–200 |
| `shared_buffers` | 1 GB | ~25% do limite, com teto de 2 GB |
| `effective_cache_size` | 2 GB | é dica de planner, não aloca |
| `work_mem` | 8 MB | é por nó de sort/hash, não por conexão |
| `maintenance_work_mem` | 128 MB | vacuum/criação de índice |
| `temp_buffers` | 16 MB | por sessão; não exagere |
| `idle_in_transaction_session_timeout` | 60s | evita transação aberta esquecida |
| `idle_session_timeout` | 15min | opcional; só com pooler/reconnect |
| `log_temp_files` | 1024 | loga temp files > 1 MB |

Regra prática para `shared_buffers`: **25% do limite de memória**, com piso de
256 MB e teto de 2 GB. Se o limite for 2 GB, use 512 MB; se for 4 GB, use 1 GB;
se for 8 GB, use 2 GB.

Duas formas de aplicar:

**A. Custom Start Command na Railway** (recomendado; o comando é passado ao
entrypoint):

```text
postgres -p 5432 -c listen_addresses=* -c shared_buffers=1GB -c effective_cache_size=2GB -c work_mem=8MB -c maintenance_work_mem=128MB -c max_connections=4000 -c idle_in_transaction_session_timeout=60s -c log_temp_files=1024
```

**B. `ALTER SYSTEM` + restart único**:

```sql
ALTER SYSTEM SET shared_buffers = '1GB';
ALTER SYSTEM SET max_connections = '4000';
ALTER SYSTEM SET effective_cache_size = '2GB';
ALTER SYSTEM SET work_mem = '8MB';
ALTER SYSTEM SET maintenance_work_mem = '128MB';
ALTER SYSTEM SET temp_buffers = '16MB';
ALTER SYSTEM SET idle_in_transaction_session_timeout = '60s';
ALTER SYSTEM SET log_temp_files = 1024;
-- opcional, só se o app reconecta ou usa PgBouncer:
-- ALTER SYSTEM SET idle_session_timeout = '15min';
SELECT pg_reload_conf();
```

`shared_buffers` e `max_connections` exigem restart para valer. É um restart
único de configuração, não um restart periódico.

Também vale atacar a causa: revisar as queries grandes com
`EXPLAIN (ANALYZE, BUFFERS)`, criar índices, evitar `SELECT *`, paginar, e usar
PgBouncer em transaction pooling. Uma query que lê 10 GB sempre vai aquecer
10 GB de cache; o reclaimer só impede que isso vire fatura permanente.

---

## 3. O que tem neste repositório

| Arquivo | Função |
|---|---|
| `Dockerfile` | imagem PostgreSQL 17; instala `vmtouch`, troca só o entrypoint |
| `Dockerfile.18` | imagem PostgreSQL 18; mesma receita, com `PGDATA` fixado no path do template |
| `entrypoint-wrapper.sh` | sobe o reclaimer e faz `exec` no `wrapper.sh` original |
| `pg-cache-reclaim.sh` | loop de verificação + `vmtouch -e` com guardrails |
| `diagnose-memory.sh` | diagnóstico read-only de cgroup, processos, settings e queries |
| `tuning.sql` | sugestão inicial de `ALTER SYSTEM` para memória/conexões |

---

## 4. Deploy

### 4.1 Build e push da imagem

Na raiz deste repositório:

```bash
# PostgreSQL 17
docker buildx build \
  --platform linux/amd64 \
  -f Dockerfile \
  -t ghcr.io/sermi13/postgres-railway-optimized:17 \
  --push .

# PostgreSQL 18
docker buildx build \
  --platform linux/amd64 \
  -f Dockerfile.18 \
  -t ghcr.io/sermi13/postgres-railway-optimized:18 \
  --push .
```

A Railway roda `linux/amd64`. Se você buildar em Mac ARM, o `--platform` é
obrigatório.

### 4.2 Apontar o serviço para a imagem

**Service → Settings → Source → Docker Image**:

```text
# PostgreSQL 17
ghcr.io/sermi13/postgres-railway-optimized:17

# PostgreSQL 18
ghcr.io/sermi13/postgres-railway-optimized:18
```

Alternativamente, conecte este repositório no GitHub e deixe a Railway buildar
o `Dockerfile` (17). Para 18, configure `RAILWAY_DOCKERFILE_PATH=Dockerfile.18`
ou use a imagem já publicada.

Mantenha:

- volume em `/var/lib/postgresql/data`;
- as mesmas variáveis de ambiente (`PGDATA`, `POSTGRES_PASSWORD`, PITR etc.);
- o mesmo `CMD`/start command, se você já usa um.

**Importante para o PostgreSQL 18:** a imagem oficial 18 usa por padrão
`PGDATA=/var/lib/postgresql/18/docker`. O `Dockerfile.18` fixa
`PGDATA=/var/lib/postgresql/data` para manter a convenção de volume do
template Railway. Não aponte a imagem 18 para um volume que já contém dados do
PostgreSQL 17: o PostgreSQL 18 não abre um data directory 17. Use um volume
novo ou o fluxo de major upgrade da Railway.

O `CMD` da imagem já inclui `-c max_connections=4000`. Se você usa um
**Custom Start Command**, ele substitui o `CMD` inteiro; nesse caso inclua
`-c max_connections=4000` explicitamente, senão o valor volta ao default ou ao
`500` gravado pelo template no `auto.conf`.

O primeiro deploy da imagem custom é um restart. Depois dele, os trims são
feitos em runtime, sem restart.

### 4.3 Variáveis de ambiente (opcionais)

Os defaults já funcionam. Para ajustar:

```text
CACHE_RECLAIM_ENABLED=true
CACHE_RECLAIM_INTERVAL_SECONDS=60
CACHE_RECLAIM_THRESHOLD_MB=2048
CACHE_RECLAIM_MIN_INTERVAL_SECONDS=900
CACHE_RECLAIM_TARGETS=/var/lib/postgresql/data/base,/var/lib/postgresql/data/global,/var/lib/postgresql/data/pg_tblspc,/var/lib/postgresql/data/pg_wal,/var/lib/postgresql/data/pgbackrest-spool
CACHE_RECLAIM_SKIP_LONG_QUERIES=true
CACHE_RECLAIM_LONG_QUERY_SECONDS=30
CACHE_RECLAIM_SKIP_BACKUP=true
CACHE_RECLAIM_TIMEOUT_SECONDS=300
CACHE_RECLAIM_DRY_RUN=false
```

Perfis:

| Perfil | `THRESHOLD_MB` | `MIN_INTERVAL` | Efeito |
|---|---:|---:|---|
| Economia agressiva | 512 | 3600 | menos RAM, mais leitura de disco |
| Equilibrado | 2048 | 900 | bom ponto de partida |
| Performance primeiro | 4096 | 1800 | menos impacto de I/O |

Comece com o equilibrado. Se aparecer aumento de latência de leitura, suba o
threshold ou o `shared_buffers`.

---

## 5. Validação

### Logs

Você deve ver linhas assim no log do serviço:

```text
2026-10-26T15:00:00Z pg-cache-reclaim: starting (interval=60s threshold=2048MB min_interval=900s ...)
2026-10-26T15:12:03Z pg-cache-reclaim: trimming: file=9340MB inactive=9100MB anon=310MB current=9720MB limit=4096MB
2026-10-26T15:12:18Z pg-cache-reclaim: trim finished rc=0: file=9340MB -> 210MB, current=9720MB -> 620MB
```

### Antes/depois

```bash
# antes
cat /sys/fs/cgroup/memory.stat | egrep '^(anon|file|inactive_file) '
cat /sys/fs/cgroup/memory.current

# depois do trim
cat /sys/fs/cgroup/memory.stat | egrep '^(anon|file|inactive_file) '
cat /sys/fs/cgroup/memory.current
```

No gráfico da Railway, a queda aparece na próxima amostra (até ~30 s).

### Teste manual do vmtouch

```bash
vmtouch -v /var/lib/postgresql/data/base | tail -5
vmtouch -e -f /var/lib/postgresql/data/base /var/lib/postgresql/data/global
cat /sys/fs/cgroup/memory.stat | egrep '^(anon|file|inactive_file) '
```

Se o `file` não cair, o filesystem do volume pode não honrar `fadvise`. Nesse
caso, a camada 1 (limite de memória) continua funcionando como teto.

---

## 6. Riscos e cuidados

1. **Latência de leitura**: evictar cache esfria o banco. A próxima query relê
   do volume. Por isso o default tem threshold de 2 GB, intervalo mínimo de
   15 min e prioridade baixa. Ajuste conforme sua latência.
2. **Não é solução oficial do template**: é uma imagem derivada. Teste em
   staging/homologação antes de produção.
3. **`vmtouch` só remove páginas limpas**. Páginas sujas aguardam writeback;
   isso é intencional (não forçamos `sync` para não gerar pico de I/O).
4. **`shared_buffers` não é trimado**: é memória compartilhada do PostgreSQL.
   Se você aumentar para 2 GB, esse valor é fixo e entra na conta; o ganho é
   não depender tanto do page cache.
5. **Limite de memória muito baixo** pode causar OOM em query grande. Monitore
   `anon` e o gráfico antes de apertar.
6. **Backup/PITR**: o reclaimer pula enquanto `pgbackrest` está rodando, mas
   depois do backup ele trimma. Se o backup for muito frequente, considere
   aumentar o intervalo mínimo.
7. **4000 conexões**: é um teto alto e perigoso sem pooler. 4000 backends
   ociosos podem consumir dezenas de GB, e cada conexão usa um file descriptor.
   Confira `ulimit -n` e prefira PgBouncer. O valor está no `CMD` da imagem;
   para mudar, edite o `Dockerfile` ou sobrescreva com um Custom Start Command
   que inclua `-c max_connections=...`.

### O que NÃO recomendamos

- `echo 3 > /proc/sys/vm/drop_caches`: em container normalmente é read-only e,
  quando funciona, afeta o host inteiro. Pode derrubar performance de outros
  serviços.
- `echo ... > /sys/fs/cgroup/memory.reclaim`: no Docker/Railway o
  `/sys/fs/cgroup` é montado read-only; não funciona sem privilégio.
- `cron` com `pg_ctl restart`: resolve a RAM, mas gera downtime e recuperação
  de WAL. É exatamente o que queremos evitar.
- Aumentar `shared_buffers` para “todo o banco”: vira memória fixa e cara.

---

## 7. Conta rápida

A Railway cobra cerca de **US$ 10/GB/mês** de RAM.

| Uso | Custo aproximado |
|---:|---:|
| 10 GB | ~US$ 100/mês |
| 4 GB | ~US$ 40/mês |
| 2 GB | ~US$ 20/mês |

Sair de 10 GB para ~2 GB economiza cerca de **US$ 80/mês** por réplica, o que
paga com folga o esforço de operar a imagem custom.

---

## 8. Rollback

Basta voltar a imagem do serviço para a versão correspondente do template:

```text
# PostgreSQL 17
ghcr.io/railwayapp-templates/postgres-ssl:17

# PostgreSQL 18
ghcr.io/railwayapp-templates/postgres-ssl:18
```

Use a tag que corresponde ao data directory do volume; não misture 17 e 18 no
mesmo volume. O volume e os dados não são tocados pelo rollback da imagem. Se
você aplicou `ALTER SYSTEM`, os parâmetros continuam no
`postgresql.auto.conf`; reverta com `ALTER SYSTEM RESET ...` se quiser voltar ao
default.

---

## 9. Resumo executivo

- O consumo de 10 GB é, quase certamente, **page cache** (`file` no
  `memory.stat`), não vazamento do PostgreSQL.
- **Camada 1**: limite de memória na Railway, para o kernel reciclar cache e
  evitar crescimento sem teto.
- **Camada 2**: imagem custom com `vmtouch -e` para **baixar** o cache em
  runtime, sem restart, com threshold e guardrails.
- **Camada 3**: controlar `max_connections` (teto alto com PgBouncer na
  frente), ajustar `work_mem` e otimizar as queries grandes.
- Valide sempre com `diagnose-memory.sh`: se `anon` for o maior valor, o
  problema é outro e o reclaimer não vai resolver.
