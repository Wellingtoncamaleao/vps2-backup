# Imagem de backup dos Postgres da VPS2 Hetzner (Zitadel + Coolify + futuros).
# Padrao gemeo do scripts/backup-supabase (control-bkp na VPS1), com diferenca:
# este container nao conecta via URL externa, ele entra no Postgres alvo via
# `docker exec` (precisa do docker.sock montado read-only).
#
# Base postgres:17-alpine -> pg_dump/pg_restore 17, compativel com Postgres 15+.
FROM postgres:17-alpine

# rclone -> offsite (Backblaze B2); curl -> alerta Telegram; docker-cli -> exec
RUN apk add --no-cache rclone curl docker-cli

COPY backup-vps2.sh /usr/local/bin/backup-vps2.sh
RUN chmod +x /usr/local/bin/backup-vps2.sh

# Agendamento interno: crond dispara diariamente (ver arquivo `crontab`).
COPY crontab /etc/crontabs/root
RUN chmod 0600 /etc/crontabs/root

# crond em foreground mantem o container vivo e dispara no horario.
# ENTRYPOINT vazio sobrepoe o entrypoint do postgres (que iniciaria o banco).
ENTRYPOINT []
CMD ["crond", "-f", "-l", "8"]
