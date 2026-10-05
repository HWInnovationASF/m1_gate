#!/usr/bin/env bash
# pyGate installer/updater — รองรับ Debian/Ubuntu/Raspberry Pi OS (apt), RHEL/Fedora/Rocky (dnf/yum), Arch (pacman)
# ติดตั้ง: Python libs (venv) + Apache + PHP + MySQL/MariaDB + front-end -> web root + systemd service
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_SRC="${INSTALLER_SRC:-$SCRIPT_DIR}"
if [[ -z "${SOURCE_DIR:-}" ]]; then                        # โฟลเดอร์ที่มี app.py
  if [[ -f "$SCRIPT_DIR/../app.py" ]]; then SOURCE_DIR="$(dirname "$SCRIPT_DIR")"
  else SOURCE_DIR="$SCRIPT_DIR/source"; fi                 # กรณีเรียกจาก /opt/m1-installer
fi
SOURCE_DIR="$(readlink -f "$SOURCE_DIR")"
APP_DEST="${APP_DEST:-/opt/pygate}"
RUN_USER="${RUN_USER:-${SUDO_USER:-mdbcare}}"
WEB_STACK="${WEB_STACK:-lamp}"                             # lamp | none
WEB_DEST="${WEB_DEST:-/var/www/html}"
FRONTEND_SRC="${FRONTEND_SRC:-}"
PROXY="${PROXY:-0}"
SERVICE_NAME="${SERVICE_NAME:-pygate.service}"
APP_PORT="${APP_PORT:-8811}"
DB_NAME="${DB_NAME:-pygate}"
DB_APP_USER="${DB_APP_USER:-pygate}"
DB_APP_PASSWORD="${DB_APP_PASSWORD:-}"
SKIP_SERVICE="${SKIP_SERVICE:-0}"
YES="${YES:-0}"
M1_INSTALLER_DEST="${M1_INSTALLER_DEST:-/opt/m1-installer}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/pygate}"
KEEP_BACKUPS="${KEEP_BACKUPS:-3}"

[[ $EUID -eq 0 ]] || { echo "กรุณารันด้วย root: sudo m1 install" >&2; exit 1; }
[[ -f "$SOURCE_DIR/app.py" ]] || { echo "ไม่พบ app.py ใน $SOURCE_DIR (ตั้ง SOURCE_DIR=...)" >&2; exit 1; }
[[ "$WEB_STACK" =~ ^(lamp|none)$ ]] || { echo "WEB_STACK ต้องเป็น lamp หรือ none" >&2; exit 1; }
[[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ && "$DB_APP_USER" =~ ^[A-Za-z0-9_]+$ ]] || { echo "DB_NAME/DB_APP_USER ไม่ถูกต้อง" >&2; exit 1; }
[[ "$KEEP_BACKUPS" =~ ^[0-9]+$ ]] || { echo "KEEP_BACKUPS ต้องเป็นตัวเลข" >&2; exit 1; }
trap 'echo "ติดตั้งไม่สำเร็จที่บรรทัด $LINENO" >&2' ERR

# ---------- ตรวจ OS / package manager ----------
OS_ID="unknown"; OS_LIKE=""
if [[ -r /etc/os-release ]]; then . /etc/os-release; OS_ID="${ID:-unknown}"; OS_LIKE="${ID_LIKE:-}"; fi
if   command -v apt-get >/dev/null; then PM=apt
elif command -v dnf     >/dev/null; then PM=dnf
elif command -v yum     >/dev/null; then PM=yum
elif command -v pacman  >/dev/null; then PM=pacman
else echo "ไม่รองรับ OS นี้ ($OS_ID) — ต้องมี apt/dnf/yum/pacman" >&2; exit 1; fi

case "$PM" in
  apt)
    WEB_SVC=apache2; WEB_USER=www-data
    BASE_PKGS=(python3 python3-pip python3-venv git rsync p7zip-full openssl sudo)
    LAMP_PKGS=(apache2 mariadb-server php php-cli php-mysql php-curl php-mbstring php-xml php-zip libapache2-mod-php)
    DB_SVC=mariadb ;;
  dnf|yum)
    WEB_SVC=httpd; WEB_USER=apache
    BASE_PKGS=(python3 python3-pip git rsync p7zip openssl sudo)
    LAMP_PKGS=(httpd mariadb-server php php-cli php-mysqlnd php-mbstring php-xml php-json)
    DB_SVC=mariadb ;;
  pacman)
    WEB_SVC=httpd; WEB_USER=http
    BASE_PKGS=(python python-pip git rsync p7zip openssl sudo)
    LAMP_PKGS=(apache mariadb php php-apache)
    DB_SVC=mariadb ;;
esac

pkg_install() {
  case "$PM" in
    apt)    apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf)    dnf install -y "$@" ;;
    yum)    yum install -y "$@" ;;
    pacman) pacman -Sy --needed --noconfirm "$@" ;;
  esac
}

# PyPI libs ของ pyGate (อ่านจาก requirements.txt ถ้ามี โดยตัด flag ที่ไม่ใช่ของ venv)
PY_LIBS=(Flask flask-mqtt flask-socketio PyMySQL requests python-dotenv paho-mqtt)

echo "==================================================="
echo " pyGate installer"
echo " OS / pkg manager : $OS_ID / $PM"
echo " Source           : $SOURCE_DIR"
echo " App destination  : $APP_DEST   (run as $RUN_USER)"
echo " Web stack        : $WEB_STACK  -> $WEB_DEST"
echo "==================================================="
if [[ "$YES" != "1" ]]; then
  read -r -p "ดำเนินการติดตั้ง/อัปเดตหรือไม่? พิมพ์ yes: " answer
  [[ "$answer" == "yes" ]] || { echo "ยกเลิก"; exit 0; }
fi

id "$RUN_USER" >/dev/null 2>&1 || { echo "==> สร้าง user: $RUN_USER"; useradd --create-home --shell /bin/bash "$RUN_USER"; }

# ---------- 1) system packages ----------
echo "==> ติดตั้ง system packages"
pkg_install "${BASE_PKGS[@]}"
[[ "$WEB_STACK" == "lamp" ]] && pkg_install "${LAMP_PKGS[@]}"

# ---------- 2) backup ค่าที่ต้องเก็บ ----------
PRESERVE=(.env gate_config.json alarm_config.json gate_config_cases.json lid_list dlog logs)
ts="$(date +%Y%m%d_%H%M%S)"; backup_dir="$BACKUP_ROOT/$ts"
mkdir -p "$backup_dir"
for item in "${PRESERVE[@]}"; do
  [[ -e "$APP_DEST/$item" ]] && cp -a "$APP_DEST/$item" "$backup_dir/" || true
done
echo "==> Backup config: $backup_dir"

# ---------- 3) แอป ----------
echo "==> คัดลอกแอป -> $APP_DEST (เก็บ config/log เดิมไว้)"
mkdir -p "$APP_DEST"
rsync -a \
  --exclude='/.git/' --exclude='/installer/' --exclude='__pycache__/' --exclude='*.pyc' \
  --exclude='*.bak*' --exclude='*.pre_*' --exclude='*.test_damaged' --exclude='*.lock' \
  --exclude='/backup_*/' --exclude='/venv/' --exclude='/presence_preview/' \
  --exclude='/.env' --exclude='/gate_config.json' --exclude='/gate_config.json.prev' \
  --exclude='/alarm_config.json' --exclude='/lid_list/' --exclude='/dlog/' --exclude='/logs/' \
  "$SOURCE_DIR/" "$APP_DEST/"
# seed ไฟล์ตั้งต้นเฉพาะเครื่องใหม่
for item in .env gate_config.json alarm_config.json; do
  [[ -e "$APP_DEST/$item" || ! -e "$SOURCE_DIR/$item" ]] || cp -a "$SOURCE_DIR/$item" "$APP_DEST/$item"
done
mkdir -p "$APP_DEST"/{logs,dlog,lid_list}

# ---------- 4) Python libraries (venv — ไม่ชนกับ system python) ----------
echo "==> ติดตั้ง/อัปเดต Python libraries"
[[ -x "$APP_DEST/venv/bin/python" ]] || python3 -m venv --system-site-packages "$APP_DEST/venv"
PIP=("$APP_DEST/venv/bin/python" -m pip --disable-pip-version-check)
"${PIP[@]}" install --upgrade pip >/dev/null
if [[ -f "$SOURCE_DIR/requirements.txt" ]]; then
  # ตัด --break-system-packages ออก เพราะใช้ venv
  sed 's/[[:space:]]*--break-system-packages//' "$SOURCE_DIR/requirements.txt" | grep -v '^[[:space:]]*$' > "$APP_DEST/requirements.txt" || true
  grep -qE '^(pip install|#)' "$APP_DEST/requirements.txt" && sed -i -E '/^(pip install|#)/d' "$APP_DEST/requirements.txt"
  "${PIP[@]}" install -U -r "$APP_DEST/requirements.txt"
else
  "${PIP[@]}" install -U "${PY_LIBS[@]}"
fi

# ---------- 5) Web stack: Apache + PHP + MySQL ----------
if [[ "$WEB_STACK" == "lamp" ]]; then
  echo "==> เปิด $WEB_SVC และ $DB_SVC"
  command -v systemctl >/dev/null && systemctl enable --now "$DB_SVC" "$WEB_SVC"

  # DB: สร้างฐานข้อมูลและ user (รหัสผ่านสุ่มถ้าไม่ระบุ; เก็บใน .env ถ้ายังไม่มี)
  env_get() { grep -E "^$1=" "$APP_DEST/.env" 2>/dev/null | head -1 | cut -d= -f2- || true; }
  [[ -n "$DB_APP_PASSWORD" ]] || DB_APP_PASSWORD="$(env_get db_pass)"
  [[ -n "$DB_APP_PASSWORD" ]] || DB_APP_PASSWORD="$(openssl rand -hex 12)"
  [[ "$DB_APP_PASSWORD" =~ ^[A-Za-z0-9@._%+=:-]+$ ]] || { echo "DB_APP_PASSWORD มีอักขระที่ไม่รองรับ" >&2; exit 1; }
  if mariadb -e 'SELECT 1' >/dev/null 2>&1; then
    mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4;
CREATE USER IF NOT EXISTS '$DB_APP_USER'@'localhost' IDENTIFIED BY '$DB_APP_PASSWORD';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_APP_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
    echo "==> DB พร้อม: $DB_NAME (user $DB_APP_USER)"
    touch "$APP_DEST/.env"
    for kv in "db_host=localhost" "db_user=$DB_APP_USER" "db_pass=$DB_APP_PASSWORD"; do
      grep -qE "^${kv%%=*}=" "$APP_DEST/.env" || echo "$kv" >> "$APP_DEST/.env"
    done
  else
    echo "!! เข้า MariaDB ด้วย root socket ไม่ได้ — ข้ามการสร้าง DB (ตั้งเองภายหลัง)" >&2
  fi

  # Front-end -> web root
  if [[ -z "$FRONTEND_SRC" ]]; then
    for c in html frontend; do [[ -d "$SOURCE_DIR/$c" ]] && { FRONTEND_SRC="$SOURCE_DIR/$c"; break; }; done
  fi
  if [[ -n "$FRONTEND_SRC" && -d "$FRONTEND_SRC" ]]; then
    echo "==> ลง front-end: $FRONTEND_SRC -> $WEB_DEST"
    mkdir -p "$WEB_DEST"
    rsync -a --exclude='config/' --exclude='data/' --exclude='log*/' "$FRONTEND_SRC/" "$WEB_DEST/"
    chown -R "$RUN_USER:$WEB_USER" "$WEB_DEST"
    find "$WEB_DEST" -type d -exec chmod 0755 {} +
    find "$WEB_DEST" -type f -exec chmod 0644 {} +
  else
    echo "-- ไม่พบโฟลเดอร์ front-end (html/ หรือ frontend/) — ข้ามขั้นตอนนี้ (ระบุด้วย FRONTEND_SRC=...)"
  fi

  # Reverse proxy ไปที่ Flask (ถ้าสั่ง PROXY=1)
  if [[ "$PROXY" == "1" && "$PM" == "apt" ]]; then
    a2enmod proxy proxy_http proxy_wstunnel rewrite >/dev/null
    cat > /etc/apache2/conf-available/pygate.conf <<CONF
ProxyPreserveHost On
RewriteEngine On
RewriteCond %{HTTP:Upgrade} =websocket [NC]
RewriteRule ^/pygate/(socket\.io/.*)$ ws://127.0.0.1:$APP_PORT/\$1 [P,L]
ProxyPass        /pygate/ http://127.0.0.1:$APP_PORT/
ProxyPassReverse /pygate/ http://127.0.0.1:$APP_PORT/
CONF
    a2enconf pygate >/dev/null
    apache2ctl configtest
  elif [[ "$PROXY" == "1" ]]; then
    echo "-- PROXY=1 รองรับเฉพาะ Debian/Ubuntu ตอนนี้ — ข้าม" >&2
  fi
  command -v systemctl >/dev/null && systemctl restart "$WEB_SVC"
fi

# ---------- 6) สิทธิ์ ----------
chown -R "$RUN_USER:$RUN_USER" "$APP_DEST"
chmod 0600 "$APP_DEST/.env" 2>/dev/null || true
"$APP_DEST/venv/bin/python" -m py_compile "$APP_DEST/app.py"

# ---------- 7) ติดตั้งคำสั่ง m1 ----------
echo "==> ติดตั้งคำสั่ง m1"
mkdir -p "$M1_INSTALLER_DEST"
for f in install.sh m1 INSTALL.md; do
  [[ -f "$INSTALLER_SRC/$f" ]] || continue
  [[ "$(readlink -f "$INSTALLER_SRC/$f")" == "$(readlink -f "$M1_INSTALLER_DEST/$f" 2>/dev/null || true)" ]] \
    || install -m 0755 "$INSTALLER_SRC/$f" "$M1_INSTALLER_DEST/$f"
done
# ให้ m1 หา app.py ได้แม้เรียกจากที่อื่น: เก็บ source ล่าสุดไว้ใต้ installer dir
if [[ "$SOURCE_DIR" != "$(readlink -f "$M1_INSTALLER_DEST/source")" ]]; then
  mkdir -p "$M1_INSTALLER_DEST/source"
  rsync -a --delete --exclude='/venv/' --exclude='.git/' --exclude='/installer/' \
    --exclude='/.env' --exclude='__pycache__/' "$SOURCE_DIR/" "$M1_INSTALLER_DEST/source/"
fi
[[ -f "$M1_INSTALLER_DEST/m1" ]] && install -m 0755 "$M1_INSTALLER_DEST/m1" /usr/local/bin/m1

# ---------- 8) systemd service ----------
if [[ "$SKIP_SERVICE" != "1" ]] && command -v systemctl >/dev/null; then
  echo "==> ตั้งค่า $SERVICE_NAME"
  cat > "/etc/systemd/system/$SERVICE_NAME" <<UNIT
[Unit]
Description=pyGate Flask application
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$APP_DEST
Environment=PYTHONUNBUFFERED=1
ExecStart=$APP_DEST/venv/bin/python $APP_DEST/app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null
  systemctl restart "$SERVICE_NAME"
  sleep 2
  systemctl is-active --quiet "$SERVICE_NAME" || { systemctl status "$SERVICE_NAME" --no-pager || true; exit 1; }
fi

# ---------- 9) ล้าง backup เก่า ----------
if ((KEEP_BACKUPS == 0)); then rm -rf -- "$backup_dir"; else
  mapfile -t old < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r | tail -n +$((KEEP_BACKUPS + 1)))
  for o in "${old[@]}"; do [[ "$o" =~ ^[0-9]{8}_[0-9]{6}$ ]] && rm -rf -- "$BACKUP_ROOT/$o"; done
fi

echo "==================================================="
echo "ติดตั้ง pyGate สำเร็จ"
echo "App     : $APP_DEST  (http://<ip>:$APP_PORT)"
[[ "$WEB_STACK" == "lamp" ]] && echo "Web     : $WEB_DEST  (Apache+PHP+MariaDB)"
echo "Backup  : $backup_dir"
echo "ตรวจสอบ : m1 status | m1 logs"
echo "==================================================="
