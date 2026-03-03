#!/usr/bin/env bash
set -euo pipefail

# ====== Colors ======
BLUE='\033[0;34m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()  { echo -e "${GREEN}[OK]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
die() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Jalankan sebagai root: sudo bash Anti-kill.sh"
}

# ====== Paths / Names (AldyZx Anti Kill) ======
APP_NAME="AldyZx Anti Kill"

CONF_DIR="/etc/aldyzx"
CONF_FILE="${CONF_DIR}/anti-kill.conf"
SERVICES_FILE="${CONF_DIR}/anti-kill.services"

BIN_PATH="/usr/local/bin/aldyzx-anti-kill.sh"

UNIT_NAME="aldyzx-anti-kill"
SERVICE_UNIT="/etc/systemd/system/${UNIT_NAME}.service"
TIMER_UNIT="/etc/systemd/system/${UNIT_NAME}.timer"

write_default_conf_if_missing() {
  install -d -m 755 "${CONF_DIR}"
  if [[ ! -f "${CONF_FILE}" ]]; then
    cat > "${CONF_FILE}" <<'EOF'
# AldyZx Anti Kill Config

# RAM trigger: freeze when used% >= this
RAM_USED_PCT_TRIGGER=80

# Unfreeze when available RAM >= this (MB)
RAM_AVAILABLE_MB_UNFREEZE=2048

# Additional hysteresis to avoid flapping
RAM_USED_PCT_UNFREEZE=75

# CPU trigger (0 disables)
CPU_USED_PCT_TRIGGER=80
EOF
    ok "Buat config default: ${CONF_FILE}"
  else
    warn "Config sudah ada, tidak diubah: ${CONF_FILE}"
  fi
}

write_default_services_if_missing() {
  install -d -m 755 "${CONF_DIR}"
  if [[ ! -f "${SERVICES_FILE}" ]]; then
    cat > "${SERVICES_FILE}" <<'EOF'
nginx
php8.3-fpm
redis-server
mariadb
mysql
wings
EOF
    ok "Buat list service default: ${SERVICES_FILE}"
  else
    warn "Services list sudah ada, tidak diubah: ${SERVICES_FILE}"
  fi
}

write_guard_script() {
  # Tulis logic guard (gabungan pressure_guard.sh) ke BIN_PATH
  cat > "${BIN_PATH}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# AldyZx Anti Kill - Guard Runner
STATE_DIR="/var/run/aldyzx"
STATE_FILE="${STATE_DIR}/anti-kill.state"
CONFIG_FILE="/etc/aldyzx/anti-kill.conf"
SERVICES_FILE="/etc/aldyzx/anti-kill.services"

mkdir -p "${STATE_DIR}"

# Defaults (override in /etc/aldyzx/anti-kill.conf)
RAM_USED_PCT_TRIGGER=80
RAM_AVAILABLE_MB_UNFREEZE=2048
RAM_USED_PCT_UNFREEZE=75
CPU_USED_PCT_TRIGGER=80

# Default services (override by /etc/aldyzx/anti-kill.services)
SERVICES=(nginx php8.3-fpm redis-server mariadb mysql wings)

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

if [[ -f "${SERVICES_FILE}" ]]; then
  # Read file lines into SERVICES array (includes potential empty lines)
  mapfile -t SERVICES < "${SERVICES_FILE}"
fi

get_mem_kb() {
  awk -v key="$1" '$1==key":" {print $2}' /proc/meminfo
}

mem_total_kb="$(get_mem_kb MemTotal)"
mem_avail_kb="$(get_mem_kb MemAvailable)"
if [[ -z "${mem_total_kb}" || -z "${mem_avail_kb}" ]]; then
  exit 0
fi

mem_used_pct=$(( ( (mem_total_kb - mem_avail_kb) * 100 ) / mem_total_kb ))
mem_avail_mb=$(( mem_avail_kb / 1024 ))

cpu_used_pct=0
if [[ "${CPU_USED_PCT_TRIGGER}" -gt 0 ]]; then
  read -r cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
  total1=$((user+nice+system+idle+iowait+irq+softirq+steal))
  idle1=$((idle+iowait))
  sleep 1
  read -r cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
  total2=$((user+nice+system+idle+iowait+irq+softirq+steal))
  idle2=$((idle+iowait))
  totald=$((total2-total1))
  idled=$((idle2-idle1))
  if [[ "${totald}" -gt 0 ]]; then
    cpu_used_pct=$(( ( (totald - idled) * 100 ) / totald ))
  fi
fi

should_freeze=false
if [[ "${mem_used_pct}" -ge "${RAM_USED_PCT_TRIGGER}" ]]; then
  should_freeze=true
fi
if [[ "${CPU_USED_PCT_TRIGGER}" -gt 0 && "${cpu_used_pct}" -ge "${CPU_USED_PCT_TRIGGER}" ]]; then
  should_freeze=true
fi

# Freeze logic
if [[ "${should_freeze}" == "true" ]]; then
  if [[ ! -f "${STATE_FILE}" ]]; then
    echo "freezing" > "${STATE_FILE}"
    for svc in "${SERVICES[@]}"; do
      # Skip empty/comment lines
      [[ -z "${svc// /}" ]] && continue
      [[ "${svc}" =~ ^[[:space:]]*# ]] && continue
      systemctl is-active --quiet "${svc}" && systemctl stop "${svc}" || true
    done
    logger -t aldyzx-anti-kill "freeze: mem_used=${mem_used_pct}% mem_avail=${mem_avail_mb}MB cpu_used=${cpu_used_pct}%"
  fi
  exit 0
fi

# Unfreeze logic
if [[ -f "${STATE_FILE}" ]]; then
  if [[ "${mem_avail_mb}" -ge "${RAM_AVAILABLE_MB_UNFREEZE}" && "${mem_used_pct}" -le "${RAM_USED_PCT_UNFREEZE}" ]]; then
    rm -f "${STATE_FILE}"
    for svc in "${SERVICES[@]}"; do
      [[ -z "${svc// /}" ]] && continue
      [[ "${svc}" =~ ^[[:space:]]*# ]] && continue
      systemctl is-enabled --quiet "${svc}" && systemctl start "${svc}" || true
    done
    logger -t aldyzx-anti-kill "unfreeze: mem_used=${mem_used_pct}% mem_avail=${mem_avail_mb}MB cpu_used=${cpu_used_pct}%"
  fi
fi
EOF

  chmod 755 "${BIN_PATH}"
  ok "Guard script dibuat: ${BIN_PATH}"
}

install_units() {
  cat > "${SERVICE_UNIT}" <<EOF
[Unit]
Description=${APP_NAME} (RAM/CPU auto-freeze)
After=network.target

[Service]
Type=oneshot
ExecStart=${BIN_PATH}
EOF

  cat > "${TIMER_UNIT}" <<EOF
[Unit]
Description=Run ${APP_NAME} every 10 seconds

[Timer]
OnBootSec=20s
OnUnitActiveSec=10s
AccuracySec=1s
Unit=${UNIT_NAME}.service
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${UNIT_NAME}.timer"
}

uninstall_units() {
  systemctl disable --now "${UNIT_NAME}.timer" >/dev/null 2>&1 || true
  rm -f "${TIMER_UNIT}" "${SERVICE_UNIT}"
  systemctl daemon-reload
}

do_install() {
  require_root
  echo -e "${BLUE}[+] Installing ${APP_NAME}...${NC}"

  install -d -m 755 "${CONF_DIR}"
  write_guard_script
  write_default_conf_if_missing
  write_default_services_if_missing
  install_units

  echo -e " "
  ok "${APP_NAME} terpasang dan timer aktif."
  echo -e "${YELLOW}Cek status:${NC} systemctl status ${UNIT_NAME}.timer --no-pager"
  echo -e "${YELLOW}Config:${NC} ${CONF_FILE}"
  echo -e "${YELLOW}Services:${NC} ${SERVICES_FILE}"
}

do_uninstall() {
  require_root
  echo -e "${BLUE}[+] Uninstalling ${APP_NAME}...${NC}"

  uninstall_units
  rm -f "${BIN_PATH}"
  ok "Hapus binary: ${BIN_PATH}"

  echo -e "${YELLOW}Catatan:${NC} config tidak dihapus otomatis:"
  echo -e " - ${CONF_FILE}"
  echo -e " - ${SERVICES_FILE}"
  echo -e "${YELLOW}Jika mau hapus total:${NC} rm -rf ${CONF_DIR}"

  ok "${APP_NAME} sudah di-uninstall (timer & service dihapus)."
}

do_status() {
  echo -e " "
  systemctl status "${UNIT_NAME}.timer" --no-pager || true
  echo -e " "
  systemctl status "${UNIT_NAME}.service" --no-pager || true
  echo -e " "
  echo -e "${YELLOW}Config:${NC} ${CONF_FILE}"
  echo -e "${YELLOW}Services:${NC} ${SERVICES_FILE}"
  echo -e "${YELLOW}Binary:${NC} ${BIN_PATH}"
  echo -e " "
  read -rp "Enter untuk kembali..." _
}

show_menu() {
  clear || true
  echo -e " "
  echo -e "${BLUE}[+] =============================================== [+]${NC}"
  echo -e "${BLUE}[+]               ${APP_NAME} MANAGER               [+]${NC}"
  echo -e "${BLUE}[+] =============================================== [+]${NC}"
  echo -e " "
  echo -e "1) Install ${APP_NAME}"
  echo -e "2) Uninstall ${APP_NAME}"
  echo -e "3) Status"
  echo -e "x) Keluar"
  echo -e " "
  echo -ne "${YELLOW}Pilih opsi (1/2/3/x): ${NC}"
}

main() {
  while true; do
    show_menu
    read -r choice
    case "${choice}" in
      1) do_install; sleep 2 ;;
      2) do_uninstall; sleep 2 ;;
      3) do_status ;;
      x|X) exit 0 ;;
      *) echo -e "${RED}Pilihan tidak valid.${NC}"; sleep 1 ;;
    esac
  done
}

main "$@"
