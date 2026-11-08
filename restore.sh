#!/usr/bin/env bash
# Snapshot'ni papkaga chiqaradi va har sayt uchun bench restore buyrug'ini ko'rsatadi.
# Saytga o'zi TEGMAYDI — restore'ni ko'rsatilgan buyruq bilan o'zingiz qilasiz.
#
#   restore.sh                     — snapshot'lar ro'yxati
#   restore.sh latest              — oxirgisini chiqaradi
#   restore.sh <snapshot-id> [papka]
set -Eeuo pipefail

export HOME="${HOME:-/root}"

ENV_FILE="${FRAPPE_BACKUP_ENV:-/etc/frappe-backup.env}"
# shellcheck source=/dev/null
source "$ENV_FILE"
: "${SERVER_NAME:?}" "${BENCH_USER:?}" "${RESTIC_REPOSITORY:?}" "${RESTIC_PASSWORD_FILE:?}"
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE

SNAP="${1:-}"
if [ -z "$SNAP" ]; then
	restic snapshots --host "$SERVER_NAME"
	echo
	echo "Foydalanish: $0 <snapshot-id|latest> [papka]"
	exit 0
fi

TARGET="${2:-/home/$BENCH_USER/restore/${SNAP}-$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$TARGET"
restic restore "$SNAP" --host "$SERVER_NAME" --target "$TARGET"
# bench restore frappe user nomidan ishlaydi — fayllarni o'qiy olishi kerak
if id "$BENCH_USER" >/dev/null 2>&1; then
	chown -R "$BENCH_USER:$BENCH_USER" "$TARGET"
fi

echo
echo "Chiqarildi: $TARGET"
found=0
while IFS= read -r db; do
	found=1
	enc=""
	case "$db" in
		*-database-enc.sql.gz) enc="-enc" ;; # System Settings'da encrypt_backup yoqilgan
	esac
	prefix="${db%-database${enc}.sql.gz}"
	slug="$(basename "$prefix" | cut -d- -f2-)"
	echo
	echo "--- sayt: $slug (nuqtalar o'rniga _ yozilgan) ---"
	echo "bench --site <SAYT> restore $db \\"
	echo "    --with-public-files ${prefix}-files${enc}.tar \\"
	echo "    --with-private-files ${prefix}-private-files${enc}.tar"
	echo "encryption_key shu faylda: ${prefix}-site_config_backup${enc}.json"
done < <(find "$TARGET" -name '*-database*.sql.gz' | sort)

if [ "$found" = 0 ]; then
	echo "Database fayli topilmadi — snapshot tarkibini tekshiring: restic ls $SNAP"
fi
echo
echo "bench restore faqat MAVJUD saytga ishlaydi. Sayt yo'q bo'lsa, avval: bench new-site <SAYT>"
echo "Yangi serverga yoki yangi saytga tiklasangiz, encryption_key'ni saytning site config'iga qo'ying (README, 'Tiklash')."
