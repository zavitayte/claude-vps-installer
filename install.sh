#!/usr/bin/env bash
# Claude VPS — установщик удалённого рабочего стола с Claude Desktop
# Ubuntu 24.04, запуск под root:
#   curl -fsSL https://raw.githubusercontent.com/zavitayte/claude-vps-installer/main/install.sh | sudo bash
#
# Переменные окружения (необязательно):
#   CLAUDE_USER      имя пользователя рабочего стола (по умолчанию claude)
#   CLAUDE_PASSWORD  пароль пользователя (если не задан — сгенерируется)
#   XRDP_PUBLIC=1    слушать RDP на всех адресах (по умолчанию только localhost, вход через SSH-туннель)
#   NO_REBOOT=1      не перезагружать сервер в конце

set -Eeuo pipefail

CLAUDE_USER="${CLAUDE_USER:-claude}"
CLAUDE_PASSWORD="${CLAUDE_PASSWORD:-}"
XRDP_PUBLIC="${XRDP_PUBLIC:-0}"
NO_REBOOT="${NO_REBOOT:-0}"

KEY_URL="https://downloads.claude.ai/claude-desktop/key.asc"
KEY_FILE="/usr/share/keyrings/claude-desktop-archive-keyring.asc"
KEY_FPR="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
REPO_LIST="/etc/apt/sources.list.d/claude-desktop.list"
CRED_FILE="/root/claude-vps-credentials.txt"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# ---------- вывод ----------
c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_b=$'\e[1m'; c_0=$'\e[0m'
step_n=0
step() { step_n=$((step_n + 1)); printf '\n%s[%d] %s%s\n' "$c_b" "$step_n" "$*" "$c_0"; }
ok()   { printf '  %s✓%s %s\n' "$c_ok" "$c_0" "$*"; }
warn() { printf '  %s!%s %s\n' "$c_warn" "$c_0" "$*"; }
die()  { printf '\n%sОшибка:%s %s\n' "$c_err" "$c_0" "$*" >&2; exit 1; }
trap 'die "команда на строке $LINENO завершилась с ошибкой"' ERR

# Вопрос пользователю, работает и при запуске через "curl | bash"
ask_yes() {
  local prompt="$1" answer=""
  if [[ -r /dev/tty ]]; then
    read -r -p "$prompt [Y/n] " answer </dev/tty || answer=""
  fi
  [[ -z "$answer" || "$answer" =~ ^[YyДд] ]]
}

# Дописать строку в файл, только если её там ещё нет (повторный запуск безопасен)
append_once() {
  local line="$1" file="$2"
  touch "$file"
  grep -qxF -- "$line" "$file" || printf '%s\n' "$line" >>"$file"
}

# ---------- проверки ----------
step "Проверка системы"
[[ $EUID -eq 0 ]] || die "запустите под root: sudo bash install.sh"
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "нужна Ubuntu (найдено: ${PRETTY_NAME:-неизвестно})"
[[ "${VERSION_ID:-}" == "24.04" ]] || warn "проверено на Ubuntu 24.04, у вас ${VERSION_ID:-?} — продолжаю"
arch="$(dpkg --print-architecture)"
[[ "$arch" == "amd64" || "$arch" == "arm64" ]] || die "архитектура $arch не поддерживается (нужна amd64 или arm64)"
[[ "$CLAUDE_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "недопустимое имя пользователя: $CLAUDE_USER"

cpus="$(nproc)"
mem_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
if (( cpus < 2 || mem_mb < 3500 )); then
  warn "у сервера ${cpus} ядро(а) и ${mem_mb} МБ памяти — рекомендуется от 2 ядер и 4 ГБ"
fi
ok "Ubuntu ${VERSION_ID}, ${arch}, ${cpus} CPU, ${mem_mb} МБ RAM"

# ---------- пользователь ----------
step "Пользователь ${CLAUDE_USER}"
password_set=0
if id "$CLAUDE_USER" &>/dev/null; then
  ok "пользователь уже существует"
  if [[ -n "$CLAUDE_PASSWORD" ]]; then
    echo "${CLAUDE_USER}:${CLAUDE_PASSWORD}" | chpasswd
    password_set=1
    ok "пароль обновлён из CLAUDE_PASSWORD"
  fi
else
  adduser --disabled-password --gecos "" "$CLAUDE_USER" >/dev/null
  if [[ -z "$CLAUDE_PASSWORD" ]]; then
    CLAUDE_PASSWORD="$(tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom | head -c 16 || true)"
  fi
  echo "${CLAUDE_USER}:${CLAUDE_PASSWORD}" | chpasswd
  password_set=1
  ok "пользователь создан"
fi
if (( password_set )); then
  umask 077
  printf 'user=%s\npassword=%s\n' "$CLAUDE_USER" "$CLAUDE_PASSWORD" >"$CRED_FILE"
  umask 022
fi
USER_HOME="$(getent passwd "$CLAUDE_USER" | cut -d: -f6)"

# ---------- автообновления не ломают xrdp (до установки пакетов) ----------
step "Защита сеанса от перезапуска службы при обновлениях"
mkdir -p /etc/needrestart/conf.d
echo '$nrconf{override_rc}->{qr(^xrdp)} = 0;' >/etc/needrestart/conf.d/claude-vps.conf
ok "needrestart не будет перезапускать xrdp"

# ---------- пакеты ----------
step "Рабочий стол XFCE, xrdp, хранилище паролей, Firefox (10-30 минут)"
apt-get update -q
apt-get install -y -q curl gnupg ca-certificates \
  xfce4 xfce4-terminal xrdp dbus-x11 gnome-keyring libpam-gnome-keyring firefox x11-xkb-utils
ok "пакеты установлены"

# ---------- xrdp ----------
step "Настройка xrdp"
echo "xfce4-session" >"${USER_HOME}/.xsession"
chown "${CLAUDE_USER}:${CLAUDE_USER}" "${USER_HOME}/.xsession"
ok "сеанс XFCE для ${CLAUDE_USER}"

usermod -aG ssl-cert xrdp
ok "xrdp добавлен в группу ssl-cert"

if [[ "$XRDP_PUBLIC" != "1" ]]; then
  # Слушать только 127.0.0.1 — подключение идёт через SSH-туннель, порт 3389 не торчит в интернет
  # меняем port= только в секции [Globals], в секциях сессий свои port=
  sed -i -E '/^\[Globals\]/,/^\[/ s|^port=.*|port=tcp://.:3389|' /etc/xrdp/xrdp.ini
  ok "RDP доступен только через SSH-туннель (127.0.0.1:3389)"
else
  warn "RDP открыт на всех адресах (XRDP_PUBLIC=1) — закройте порт 3389 файрволом"
fi

if systemctl list-unit-files lightdm.service 2>/dev/null | grep -q lightdm; then
  systemctl disable --now lightdm &>/dev/null || true
  ok "экран входа lightdm выключен"
else
  ok "lightdm не установлен — пропускаю"
fi

# ---------- раскладка us/ru ----------
KB_LINE='(sleep 3; setxkbmap -layout us,ru -option grp:alt_shift_toggle) &'
append_once "$KB_LINE" "${USER_HOME}/.xsessionrc"
chown "${CLAUDE_USER}:${CLAUDE_USER}" "${USER_HOME}/.xsessionrc"
RECONNECT=/etc/xrdp/reconnectwm.sh
if [[ -f "$RECONNECT" ]] && ! grep -qxF -- "$KB_LINE" "$RECONNECT"; then
  if grep -q '^exit 0' "$RECONNECT"; then
    sed -i "/^exit 0/i ${KB_LINE}" "$RECONNECT"
  else
    printf '%s\n' "$KB_LINE" >>"$RECONNECT"
  fi
fi
ok "раскладка us/ru по Alt+Shift"

# ---------- хранилище паролей ----------
append_once 'auth optional pam_gnome_keyring.so' /etc/pam.d/xrdp-sesman
append_once 'session optional pam_gnome_keyring.so auto_start' /etc/pam.d/xrdp-sesman
ok "gnome-keyring открывается при входе"

systemctl enable xrdp &>/dev/null
systemctl restart xrdp

# ---------- репозиторий Anthropic ----------
step "Официальный репозиторий Claude Desktop"
tmp_key="$(mktemp)"
curl -fsSL "$KEY_URL" -o "$tmp_key"
gnupg_home="$(mktemp -d)"
fpr="$(GNUPGHOME="$gnupg_home" gpg --batch --with-colons --show-keys "$tmp_key" 2>/dev/null \
  | awk -F: '/^fpr:/ {print $10; exit}')"
rm -rf "$gnupg_home"
if [[ "$fpr" != "$KEY_FPR" ]]; then
  rm -f "$tmp_key"
  die "отпечаток ключа не совпал (получен: ${fpr:-пусто}, ожидался: $KEY_FPR). Установка остановлена."
fi
install -m 644 "$tmp_key" "$KEY_FILE"
rm -f "$tmp_key"
ok "ключ проверен: $KEY_FPR"

echo "deb [arch=amd64,arm64 signed-by=${KEY_FILE}] https://downloads.claude.ai/claude-desktop/apt/stable stable main" >"$REPO_LIST"
apt-get update -q
apt-get install -y -q claude-desktop
ok "Claude Desktop установлен"

# ---------- ярлык на рабочем столе ----------
desktop_file="$(ls /usr/share/applications/*laude*.desktop 2>/dev/null | head -n1 || true)"
if [[ -n "$desktop_file" ]]; then
  install -d -o "$CLAUDE_USER" -g "$CLAUDE_USER" "${USER_HOME}/Desktop"
  install -m 755 -o "$CLAUDE_USER" -g "$CLAUDE_USER" "$desktop_file" "${USER_HOME}/Desktop/"
  ok "значок Claude на рабочем столе"
fi

# ---------- итог ----------
server_ip="$(curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"

printf '\n%s================ Готово ================%s\n' "$c_ok" "$c_0"
printf 'Сервер:       %s\n' "$server_ip"
printf 'Пользователь: %s\n' "$CLAUDE_USER"
if (( password_set )); then
  printf 'Пароль:       %s%s%s  (сохранён в %s)\n' "$c_b" "$CLAUDE_PASSWORD" "$c_0" "$CRED_FILE"
else
  printf 'Пароль:       прежний (пользователь уже был)\n'
fi
cat <<EOF

На компьютере с Windows:
  1) Туннель (окно не закрывать):
     ssh -N -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -L 3390:127.0.0.1:3389 ${CLAUDE_USER}@${server_ip}
  2) Win+R -> mstsc -> localhost:3390 -> пользователь ${CLAUDE_USER}
  Или одной командой: connect.ps1 из репозитория.

Если окно рабочего стола закрывается через секунду: pkill -KILL -u ${CLAUDE_USER}
EOF

if [[ "$NO_REBOOT" == "1" ]]; then
  warn "перезагрузка пропущена (NO_REBOOT=1). Выполните reboot вручную."
elif ask_yes $'\nПерезагрузить сервер сейчас?'; then
  echo "Перезагрузка через 5 секунд..."
  sleep 5
  reboot
else
  warn "не забудьте выполнить reboot"
fi
