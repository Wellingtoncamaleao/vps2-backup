# Backup dos Postgres da VPS2 Hetzner

Backup **diário automático** dos bancos Postgres rodando na VPS2 Hetzner
(`zitadel-db`, `coolify-db`, e futuros) via `pg_dump`, com verificação de
integridade, rotação local, cópia offsite em Backblaze B2 e alerta no Telegram.

Padrão idêntico ao `scripts/backup-supabase` do MaisControl (control-bkp, VPS1).
**Diferença**: este container NÃO conecta via URL externa, ele entra no
container Postgres alvo via `docker exec` (sem expor portas dos Postgres).

## Cobertura

- ✅ `zitadel-db` — auth central (users, sessions, policies)
- ✅ `coolify-db` — configuração de TODOS os apps do Coolify
- ⏳ `chat-postgres` — quando subir `maiscontrol-chat` (basta adicionar em `TARGETS`)

NÃO cobertos (recriáveis):
- Beszel (SQLite `/beszel_data`) — só histórico de métricas
- Uptime Kuma (SQLite `/app/data`) — monitors recriáveis

## Por que existe

- VPS pode pifar a qualquer momento (físico, lógico, conta suspensa).
- Compose files de tudo estão no git, mas **dados** não.
- Sem backup, restaurar = perder usuários + sessions + config de apps Coolify.

## Como funciona

A imagem se auto-agenda: `crond` interno dispara `backup-vps2.sh` todo dia
às **08:00 UTC = 05:00 BRT** (1h após o control-bkp pra escalonar).

Cada execução, pra cada alvo em `TARGETS`:

1. `docker ps --filter name=<filter>` resolve o nome real do container (o Coolify põe sufixos com UUID + timestamp)
2. `docker exec <container> pg_dump -U <user> -d <db>` → dump custom comprimido pra `/data/backups/<apelido>-AAAA-MM-DD_HHMM.dump`
3. Confere integridade — arquivo não-vazio + TOC legível via `pg_restore --list`
4. Envia cópia offsite via `rclone copy` pro bucket B2
5. Apaga dumps locais mais velhos que `BACKUP_RETENCAO` dias
6. Manda o resultado pro Telegram — ✅ sucesso ou ❌ falha

## Configuração

Copie `.env.example` → `.env` e preencha (ou cadastre no painel Coolify):

- **`TARGETS`** — lista `apelido:filter:db:user` separada por vírgula
- **`BACKUP_RETENCAO`** — dias de retenção local (padrão 30)
- **`RCLONE_REMOTE`** — destino offsite (ex.: `b2:vps2-backups`)
- **`RCLONE_CONFIG_B2_ACCOUNT`** / **`_KEY`** — Application Key DEDICADA do bucket
- **`TELEGRAM_BOT_TOKEN`** / **`_CHAT_ID`** — reusa o bot do control-bkp

## Deploy no Coolify

1. Criar app via API (build pack `dockercompose`, repo `vps2-backup`)
2. Setar env vars no painel
3. **Importante**: o container precisa de acesso ao `docker.sock` — já no compose
4. Deploy → crond agenda automático

Restaurar manual: `docker run --rm --env-file .env -v /var/run/docker.sock:/var/run/docker.sock:ro vps2-backup backup-vps2.sh`

## Testar localmente

```bash
docker build -t vps2-backup .
docker run --rm --env-file .env -v /var/run/docker.sock:/var/run/docker.sock:ro vps2-backup backup-vps2.sh
```

## Restaurar um dump

```bash
# Listar contents
pg_restore --list zitadel-2026-05-30_0800.dump | head

# Restaurar num banco descartavel
pg_restore --no-owner --no-privileges \
  --dbname="postgresql://user:pass@host:5432/banco_teste" \
  zitadel-2026-05-30_0800.dump
```

**Backup não testado não é backup.** Faça restore drill mensal num Postgres
local pra validar que o dump tá íntegro.
