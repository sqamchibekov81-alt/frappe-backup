#!/usr/bin/env bash
# Tungi backup: bench backup (DB + fayllar) → restic → Hetzner Storage Box.
# systemd timer root nomidan ishga tushiradi. Sozlamalar: /etc/frappe-backup.env
#
#   backup.sh                — oddiy backup
#   backup.sh --test-notify  — Telegram'ga test xabar yuboradi va chiqadi
set -Eeuo pipefail

ENV_FILE="${FRAPPE_BACKUP_ENV:-/etc/frappe-backup.env}"
LOG_FILE="/var/log/frappe-backup.log"
LOCK_FILE="/run/frappe-backup.lock"
STEP="sozlamalarni o'qish"
LOCKED=0
LOG_START=0

# shellcheck source=/dev/null
source "$ENV_FILE"
: "${SERVER_NAME:?}" "${BENCH_DIR:?}" "${BENCH_USER:?}" "${STAGING_DIR:?}"
: "${RESTIC_REPOSITORY:?}" "${RESTIC_PASSWORD_FILE:?}"
KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${KEEP_MONTHLY:-6}"
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE

log() {
	echo "$(date '+%F %T') $*"
}

# Har TG_CHAT_IDS ga oddiy matn yuboradi. Telegram ishlamasa backup natijasi o'zgarmaydi.
notify() {
	local text="$1" chat
	if [ -z "${TG_BOT_TOKEN:-}" ] || [ -z "${TG_CHAT_IDS:-}" ]; then
		log "TG_BOT_TOKEN yoki TG_CHAT_IDS bo'sh — xabar yuborilmadi"
		return 0
	fi
	for chat in $TG_CHAT_IDS; do
		curl -fsS -m 20 -o /dev/null "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
			--data-urlencode "chat_id=${chat}" \
			--data-urlencode "text=${text}" ||
			log "Telegram'ga yuborilmadi (chat_id ${chat})"
	done
}

# STAGING_DIR ichini tozalaydi. Yo'l kamida ikki darajali bo'lishi shart (/ yoki /home'ni o'chirib yubormaslik uchun).
clean_staging() {
	case "$STAGING_DIR" in
		/?*/?*) ;;
		*)
			log "STAGING_DIR xavfli: '$STAGING_DIR'"
			return 1
			;;
	esac
	if [ -d "$STAGING_DIR" ]; then
		find "$STAGING_DIR" -mindepth 1 -delete
	fi
}

on_error() {
	local code=$?
	trap - ERR
	log "XATO: bosqich '$STEP', chiqish kodi $code"
	sleep 1 # tee logga yozib ulgurishi uchun
	notify "$(printf 'BACKUP XATO: %s\nBosqich: %s\nVaqt: %s\nKod: %s\n\nOxirgi log:\n%s' \
		"$SERVER_NAME" "$STEP" "$(date '+%F %T')" "$code" \
		"$(tail -n +"$((LOG_START + 1))" "$LOG_FILE" 2>/dev/null | tail -n 15 | cut -c1-200)")"
	# Boshqa backup ishlayotgan bo'lsa (lock olinmagan), uning papkasiga tegmaymiz
	if [ "$LOCKED" = 1 ]; then
		clean_staging || true
	fi
	exit "$code"
}

if [ "${1:-}" = "--test-notify" ]; then
	notify "TEST: ${SERVER_NAME} backup xabarnomasi ishlayapti ($(date '+%F %T'))"
	echo "Test xabar yuborildi (yuborilmagan bo'lsa, yuqorida sababi yozilgan)."
	exit 0
fi

if [ "$(id -u)" != 0 ]; then
	echo "backup.sh root nomidan ishga tushirilishi kerak" >&2
	exit 1
fi

# Xabarga faqat shu ishga tushirishning logi tushishi uchun
if [ -f "$LOG_FILE" ]; then
	LOG_START=$(wc -l <"$LOG_FILE")
fi
exec > >(tee -a "$LOG_FILE") 2>&1
trap on_error ERR

log "===== ${SERVER_NAME}: backup boshlandi ====="

STEP="lock"
exec 9>"$LOCK_FILE"
flock -n 9 # oldingi backup hali tugamagan bo'lsa — xato
LOCKED=1

STEP="papkani tayyorlash"
install -d -o "$BENCH_USER" -g "$BENCH_USER" -m 700 "$STAGING_DIR"
clean_staging

STEP="bench backup"
runuser -l "$BENCH_USER" -c \
	"cd '$BENCH_DIR' && bench --site all backup --with-files --backup-path '$STAGING_DIR/sites'"

STEP="meta fayllar"
META="$STAGING_DIR/meta"
mkdir -p "$META"
for f in \
	"$BENCH_DIR/sites/apps.txt" \
	"$BENCH_DIR/sites/common_site_config.json" \
	"$BENCH_DIR/config/supervisor.conf" \
	"$BENCH_DIR/config/nginx.conf"; do
	if [ -f "$f" ]; then
		cp "$f" "$META/"
	fi
done
if [ -d /etc/nginx/conf.d ]; then
	cp -r /etc/nginx/conf.d "$META/nginx-conf.d"
fi
runuser -l "$BENCH_USER" -c "cd '$BENCH_DIR' && bench version" >"$META/bench-version.txt" 2>&1 || true
crontab -l -u "$BENCH_USER" >"$META/crontab-$BENCH_USER.txt" 2>/dev/null || true

STEP="restic unlock"
restic unlock # faqat eskirgan (o'lgan jarayon qoldirgan) lock'larni olib tashlaydi

STEP="restic backup"
restic backup --host "$SERVER_NAME" --tag nightly "$STAGING_DIR"

STEP="restic forget"
restic forget --host "$SERVER_NAME" --tag nightly \
	--keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY"

if [ "$(date +%u)" = 7 ]; then
	STEP="restic prune"
	restic prune
	STEP="restic check"
	restic check
fi

STEP="tozalash"
clean_staging

log "===== ${SERVER_NAME}: backup muvaffaqiyatli tugadi ====="
