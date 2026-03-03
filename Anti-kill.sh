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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

find_guard_source() {
  # Support beberapa layout biar fleksibel
  local candidates=(
    "${SCRIPT_DIR}/pressure_guard.sh"
    "${SCRIPT_DIR}/scripts/pressure_guard.sh"
    "${REPO_DIR}/pressure_guard.sh"
    "${REPO_DIR}/scripts/pressure_guard.sh"
  )

  for f in "${candidates[@]}"; do
    if [[ -x "$f" ]]; then
      echo "$f"
      return 0
    fi
  done

  # Kalau file ada tapi belum executable, tetap kasih hint
  for f in "${candidates[@]}"; do
    if [[ -f "$f" ]]; then
      die "File ditemukan tapi belum executable: $f (jalankan: chmod +x \"$f\")"
    fi
  done

  die "pressure_guard.sh tidak ditemukan. Taruh di salah satu lokasi:\n- ${SCRIPT_DIR}/pressure_guard.sh\n- ${SCRIPT_DIR}/scripts/pressure_guard.sh\n- ${REPO_DIR}/pressure_guard.sh\n- ${REPO_DIR}/scripts/pressure_guard.sh"
}

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

  local guard_source
  guard_source="$(find_guard_source)"

  install -d -m 755 "${CONF_DIR}"
  install -m 755 "${guard_source}" "${BIN_PATH}"
  ok "Install script: ${BIN_PATH} (source: ${guard_source})"

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

  # Config biasanya jangan dihapus otomatis (biar user ga kehilangan setting)
  echo -e "${YELLOW}Catatan:${NC} config tidak dihapus otomatis:"
  echo -e " - ${CONF_FILE}"
  echo -e " - ${SERVICES_FILE}"
  echo -e "${YELLOW}Jika mau hapus total:${NC} rm -rf ${CONF_DIR}"

  ok "${APP_NAME} sudah di-uninstall (timer & service dihapus)."
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
