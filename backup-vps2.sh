#!/usr/bin/env bash
# ============================================================================
# backup-vps2.sh — dump diario dos Postgres da VPS2 Hetzner (MaisControl).
#
# Cobre: zitadel-db, coolify-db, e (futuro) chat-postgres do maiscontrol-chat.
# Faz pg_dump via `docker exec` no container Postgres (sem expor portas).
# Guarda local com rotacao + envia copia offsite via rclone + alerta Telegram.
#
# Padrao gemeo do scripts/backup-supabase do MaisControl (control-bkp na VPS1).
# Diferenca: aqui o container backup NAO conecta via URL externa, ele entra no
# container Postgres pelo docker.sock.
#
# Falha ALTO: qualquer erro encerra com codigo != 0 e dispara alerta de falha.
# ============================================================================
set -euo pipefail

# --- Configuracao via variaveis de ambiente ---
#  BACKUP_DIR          pasta dos dumps (volume persistente)   [/data/backups]
#  BACKUP_RETENCAO     dias de retencao local                 [30]
#  RCLONE_REMOTE       destino offsite rclone (ex: b2:vps2-backups)
#  TELEGRAM_BOT_TOKEN  token do bot de alerta                  [vazio = sem alerta]
#  TELEGRAM_CHAT_ID    chat/grupo destino do alerta            [vazio = sem alerta]
#  TARGETS             lista separada por vivirgula, formato `apelido:filter:db:user`
#                      apelido = nome curto no dump (ex.: zitadel)
#                      filter  = `docker ps --filter name=<filter>` (ex.: zitadel-db)
#                      db      = nome da database dentro do Postgres (ex.: zitadel)
#                      user    = role com permissao de dump (ex.: postgres)
BACKUP_DIR="${BACKUP_DIR:-/data/backups}"
BACKUP_RETENCAO="${BACKUP_RETENCAO:-30}"
RCLONE_REMOTE="${RCLONE_REMOTE:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
TARGETS="${TARGETS:-zitadel:zitadel-db:zitadel:postgres,coolify:coolify-db:coolify:coolify}"

log() { echo "[$(date -Iseconds)] $*"; }

notificar() {
    { [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; } || return 0
    curl -s -m 15 -o /dev/null \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=$1" || true
}

trap 'rc=$?; [ "$rc" -ne 0 ] && notificar "❌ Backup VPS2 FALHOU (codigo $rc) em $(date -Iseconds). Confira os Logs do Coolify."' EXIT

mkdir -p "$BACKUP_DIR"
DATA="$(date +%Y-%m-%d_%H%M)"
RESUMO=""
TOTAL_OK=0

IFS=',' read -ra ALVOS <<< "$TARGETS"
for ALVO in "${ALVOS[@]}"; do
    APELIDO="$(echo "$ALVO" | cut -d: -f1)"
    FILTER="$(echo "$ALVO"  | cut -d: -f2)"
    DB="$(echo "$ALVO"      | cut -d: -f3)"
    USER="$(echo "$ALVO"    | cut -d: -f4)"

    log "alvo: apelido=$APELIDO filter=$FILTER db=$DB user=$USER"

    # Descobre o container Postgres pelo prefixo do nome.
    CONTAINER="$(docker ps --filter "name=$FILTER" --format '{{.Names}}' | head -n1)"
    [ -n "$CONTAINER" ] || { log "ERRO: container com filter '$FILTER' nao encontrado"; exit 1; }

    ARQUIVO="$BACKUP_DIR/${APELIDO}-${DATA}.dump"
    log "dumpando $CONTAINER -> $ARQUIVO"

    # pg_dump dentro do container, formato custom comprimido.
    docker exec "$CONTAINER" pg_dump -U "$USER" -d "$DB" \
        --no-owner --no-privileges --format=custom \
        > "$ARQUIVO"

    [ -s "$ARQUIVO" ] || { log "ERRO: dump vazio ($APELIDO)"; exit 1; }
    pg_restore --list "$ARQUIVO" >/dev/null || { log "ERRO: dump corrompido ($APELIDO)"; exit 1; }

    TAMANHO="$(du -h "$ARQUIVO" | cut -f1)"
    log "dump $APELIDO OK ($TAMANHO)"
    RESUMO="${RESUMO}
• $APELIDO: $TAMANHO"
    TOTAL_OK=$((TOTAL_OK+1))
done

# Copia offsite — sem isso o backup morre junto com o VPS.
if [ -n "$RCLONE_REMOTE" ]; then
    log "enviando offsite: $RCLONE_REMOTE"
    rclone copy "$BACKUP_DIR" "$RCLONE_REMOTE" \
        --include "*-${DATA}.dump" \
        --no-traverse
    log "offsite OK"
    DESTINO="local + offsite"
else
    log "AVISO: RCLONE_REMOTE vazio — backup so local (fragil)"
    DESTINO="so local"
fi

# Rotacao local
find "$BACKUP_DIR" -maxdepth 1 -name '*.dump' -type f -mtime +"$BACKUP_RETENCAO" -delete
log "rotacao OK (retencao local: $BACKUP_RETENCAO dias)"

notificar "✅ Backup VPS2 OK ($TOTAL_OK dumps, $DESTINO) em $(date -Iseconds).${RESUMO}"
log "backup concluido."
