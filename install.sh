#!/usr/bin/env bash
# Serverga bir martalik o'rnatish (root). Qayta ishga tushirsa bo'ladi: bor narsalarni qayta yaratmaydi.
# Avval /etc/frappe-backup.env to'ldirilgan bo'lishi kerak (frappe-backup.env.example'dan).
set -Eeuo pipefail

RESTIC_VERSION="0.19.1"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE=/etc/frappe-backup.env
SSH_KEY=/root/.ssh/storagebox_ed25519
SSH_CONFIG=/root/.ssh/config

die() {
	echo "XATO: $*" >&2
	exit 1
}

# restic release faylini yuklaydi: avval oddiy havola, ishlamasa GitHub API orqali.
# curl --retry 503/504 va timeout'larda o'zi qayta urinadi. Checksum keyin baribir tekshiriladi.
# GitHub login qilmaganlarni cheklab qo'ysa: GITHUB_TOKEN berilsa, so'rovlar token bilan API orqali ketadi.
fetch_release_file() {
	local name="$1" out="$2" id
	local tag="v${RESTIC_VERSION}"
	local auth=()
	local fail_msg="GitHub vaqtincha ishlamayapti. 10-15 daqiqadan keyin qayta urining yoki GITHUB_TOKEN bilan ishga tushiring (README, 'Muammolar')"
	if [ -n "${GITHUB_TOKEN:-}" ]; then
		auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
	elif curl -fsSL --retry 5 --retry-delay 10 --max-time 300 -o "$out" \
		"https://github.com/restic/restic/releases/download/${tag}/${name}"; then
		return 0
	else
		echo "github.com'dan yuklab bo'lmadi, GitHub API orqali urinib ko'raman: $name"
	fi
	id="$(curl -fsSL --retry 5 --retry-delay 10 --max-time 60 ${auth[@]+"${auth[@]}"} \
		"https://api.github.com/repos/restic/restic/releases/tags/${tag}" |
		python3 -c 'import json,sys; print(next(a["id"] for a in json.load(sys.stdin)["assets"] if a["name"] == sys.argv[1]))' "$name")" ||
		die "$fail_msg"
	curl -fsSL --retry 5 --retry-delay 10 --max-time 300 ${auth[@]+"${auth[@]}"} \
		-H "Accept: application/octet-stream" -o "$out" \
		"https://api.github.com/repos/restic/restic/releases/assets/${id}" ||
		die "$fail_msg"
}

[ "$(id -u)" = 0 ] || die "root nomidan ishga tushiring"
[ -f "$ENV_FILE" ] || die "$ENV_FILE yo'q. Avval: cp $REPO_DIR/frappe-backup.env.example $ENV_FILE va to'ldiring"
chown root:root "$ENV_FILE"
chmod 600 "$ENV_FILE"
# shellcheck source=/dev/null
source "$ENV_FILE"

for v in SERVER_NAME BENCH_DIR BENCH_USER SB_USER SB_HOST RESTIC_REPOSITORY RESTIC_PASSWORD_FILE STAGING_DIR; do
	[ -n "${!v:-}" ] || die "$ENV_FILE da $v bo'sh"
done
case "$SB_USER$SB_HOST" in
	*XXXXX*) die "$ENV_FILE da SB_USER / SB_HOST namunadagidek qolgan — haqiqiy sub-account'ni yozing" ;;
esac
[ -d "$BENCH_DIR" ] || die "BENCH_DIR topilmadi: $BENCH_DIR"
id "$BENCH_USER" >/dev/null 2>&1 || die "BENCH_USER topilmadi: $BENCH_USER"
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE

echo "== 1/6 Paketlar va restic $RESTIC_VERSION"
echo "apt paketlari yangilanyapti, 1-2 daqiqa jim turishi mumkin. Hech narsa kiritmang, parol 4-qadamda so'raladi."
apt-get update -qq
apt-get install -y -qq curl bzip2 openssh-client util-linux >/dev/null
if [[ "$(/usr/local/bin/restic version 2>/dev/null || true)" != "restic $RESTIC_VERSION "* ]]; then
	case "$(dpkg --print-architecture)" in
		amd64) arch=amd64 ;;
		arm64) arch=arm64 ;;
		*) die "Arxitektura qo'llab-quvvatlanmaydi: $(dpkg --print-architecture)" ;;
	esac
	echo "restic GitHub'dan yuklanyapti..."
	tmp="$(mktemp -d)"
	file="restic_${RESTIC_VERSION}_linux_${arch}.bz2"
	fetch_release_file "$file" "$tmp/$file"
	fetch_release_file SHA256SUMS "$tmp/SHA256SUMS"
	(cd "$tmp" && grep " $file\$" SHA256SUMS | sha256sum -c -) || die "restic checksum mos kelmadi"
	bunzip2 -c "$tmp/$file" >/usr/local/bin/restic
	chmod 755 /usr/local/bin/restic
	rm -rf "$tmp"
fi
/usr/local/bin/restic version

echo "== 2/6 SSH kalit"
install -d -m 700 /root/.ssh
if [ ! -f "$SSH_KEY" ]; then
	ssh-keygen -q -t ed25519 -N "" -f "$SSH_KEY" -C "frappe-backup@$SERVER_NAME"
fi

echo "== 3/6 $SSH_CONFIG (Host storagebox)"
touch "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"
sed -i '/^# frappe-backup begin$/,/^# frappe-backup end$/d' "$SSH_CONFIG"
cat >>"$SSH_CONFIG" <<EOF
# frappe-backup begin
Host storagebox
    HostName $SB_HOST
    User $SB_USER
    Port 23
    IdentityFile $SSH_KEY
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ServerAliveInterval 60
    ServerAliveCountMax 240
# frappe-backup end
EOF

echo "== 4/6 Kalitni Storage Box'ga o'rnatish"
sb_ok() {
	echo pwd | sftp -q -o BatchMode=yes -b - storagebox >/dev/null 2>&1
}
if sb_ok; then
	echo "Kalit allaqachon o'rnatilgan."
else
	echo "Sub-account ($SB_USER) paroli so'raladi — bir marta kiriting:"
	ssh -p 23 -o StrictHostKeyChecking=accept-new -o PubkeyAuthentication=no \
		"$SB_USER@$SB_HOST" install-ssh-key <"$SSH_KEY.pub"
	sb_ok || die "Kalit bilan ulanib bo'lmadi. Hetzner Console'da sub-account uchun SSH support va External reachability yoqilganini tekshiring"
fi

echo "== 5/6 restic repo"
if [ ! -f "$RESTIC_PASSWORD_FILE" ]; then
	(umask 077 && head -c 32 /dev/urandom | base64 >"$RESTIC_PASSWORD_FILE")
	cat <<EOF

##########################################################################
  YANGI RESTIC PAROLI ($SERVER_NAME):

      $(cat "$RESTIC_PASSWORD_FILE")

  Hozir password manager'ga saqlang (server nomi bilan).
  Bu parolsiz backup'ni HECH QACHON ochib bo'lmaydi.
##########################################################################

EOF
	read -r -p "Saqladingizmi? Davom etish uchun 'ha' yozing: " answer
	[ "$answer" = "ha" ] || die "Parol saqlanmaguncha davom etmaymiz (fayl: $RESTIC_PASSWORD_FILE)"
fi
chmod 600 "$RESTIC_PASSWORD_FILE"
if restic cat config >/dev/null 2>&1; then
	echo "Repo allaqachon bor."
else
	restic init
fi

echo "== 6/6 systemd timer va logrotate"
chmod 755 "$REPO_DIR/backup.sh" "$REPO_DIR/restore.sh"
sed "s#/opt/frappe-backup#$REPO_DIR#g" "$REPO_DIR/systemd/frappe-backup.service" \
	>/etc/systemd/system/frappe-backup.service
cp "$REPO_DIR/systemd/frappe-backup.timer" /etc/systemd/system/frappe-backup.timer
cat >/etc/logrotate.d/frappe-backup <<'EOF'
/var/log/frappe-backup.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
EOF
systemctl daemon-reload
systemctl enable --now frappe-backup.timer
systemctl list-timers frappe-backup.timer --no-pager

cat <<EOF

Tayyor. Keyingi qadamlar:
  1) Telegram sinovi:      $REPO_DIR/backup.sh --test-notify
  2) Birinchi backup:      systemctl start frappe-backup.service   (tugashini kuting)
  3) Natija:               tail -n 30 /var/log/frappe-backup.log
                           RESTIC_REPOSITORY=$RESTIC_REPOSITORY RESTIC_PASSWORD_FILE=$RESTIC_PASSWORD_FILE restic snapshots
EOF
