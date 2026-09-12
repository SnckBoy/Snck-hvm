#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="Snck HVM"
SERVICE_NAME="snck-hvm"
INSTALL_DIR="/opt/snck-hvm"
BIN_FILE="${INSTALL_DIR}/snck-hvm"
LOG_FILE="/var/log/snck-hvm.log"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
LICENSE_API="${SNCK_LICENSE_API:-https://official.snck.fun/api/v1/license/validate}"
PANEL_PORT="${SNCK_PANEL_PORT:-8080}"
DOWNLOAD_URL="${SNCK_HVM_DOWNLOAD_URL:-https://files.catbox.moe/k9nizi}"

# ANSI colors
RESET='\033[0m'
BOLD='\033[1m'
CYAN='\033[1;36m'
BLUE='\033[1;34m'
MAGENTA='\033[1;35m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'

info(){ printf "${CYAN}▸${RESET} %s\n" "$*"; }
ok(){ printf "${GREEN}✓${RESET} %s\n" "$*"; }
warn(){ printf "${YELLOW}!${RESET} %s\n" "$*"; }
die(){ printf "${RED}✗${RESET} %s\n" "$*" >&2; exit 1; }

banner(){
    clear 2>/dev/null || true
    printf "\n${CYAN}${BOLD}"
    cat <<'EOF'
   ███████╗███╗   ██╗ ██████╗██╗  ██╗
   ██╔════╝████╗  ██║██╔════╝██║ ██╔╝
   ███████╗██╔██╗ ██║██║     █████╔╝
   ╚════██║██║╚██╗██║██║     ██╔═██╗
   ███████║██║ ╚████║╚██████╗██║  ██╗
   ╚══════╝╚═╝  ╚═══╝ ╚═════╝╚═╝  ╚═╝

                 H V M   P A N E L
EOF
    printf "${RESET}\n"
    printf "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
    printf "${WHITE}${BOLD}                 SNCK HVM INSTALLER${RESET}\n"
    printf "${GRAY}              Official: official.snck.fun${RESET}\n"
    printf "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n\n"
}

menu(){
    printf "${BLUE}${BOLD}  [1]${RESET} ${WHITE}Install Snck HVM${RESET}\n"
    printf "${BLUE}${BOLD}  [2]${RESET} ${WHITE}Repair / Reinstall${RESET}\n"
    printf "${BLUE}${BOLD}  [3]${RESET} ${WHITE}Check Service Status${RESET}\n"
    printf "${BLUE}${BOLD}  [4]${RESET} ${WHITE}Show Logs${RESET}\n"
    printf "${RED}${BOLD}  [5]${RESET} ${WHITE}Uninstall Snck HVM${RESET}\n"
    printf "${RED}${BOLD}  [0]${RESET} ${WHITE}Exit${RESET}\n\n"
}

[[ "${EUID}" -eq 0 ]] || die "Run this installer as root."

install_hvm(){
    banner
    printf "${CYAN}${BOLD}INSTALLATION${RESET}\n\n"

    export DEBIAN_FRONTEND=noninteractive
    if command -v apt-get >/dev/null 2>&1; then
        info "Updating package lists..."
        apt-get update -y
        info "Installing required dependencies..."
        apt-get install -y qemu-system cloud-image-utils wget curl ca-certificates file iproute2 lsof procps sudo
        ok "Dependencies installed."
    else
        die "This installer supports Debian/Ubuntu systems with apt-get."
    fi

    printf "\n${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
    printf "${WHITE}${BOLD}LICENSE VERIFICATION${RESET}\n\n"
    read -r -p "$(printf "${CYAN}Enter Snck HVM license: ${RESET}")" SNCK_LICENSE
    [[ -n "${SNCK_LICENSE}" ]] || die "A license is required."

    info "Validating license with official.snck.fun..."
    LICENSE_RESPONSE="$(curl -fsS --max-time 15 \
        -H 'Accept: application/json' \
        --get "${LICENSE_API}" \
        --data-urlencode "license=${SNCK_LICENSE}" \
        --data-urlencode "product=snck-hvm" \
        || true)"

    if ! printf '%s' "${LICENSE_RESPONSE}" | grep -Eq '"valid"[[:space:]]*:[[:space:]]*true'; then
        die "License validation failed. Check your license or official.snck.fun."
    fi
    ok "License accepted."

    printf "\n${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
    info "Preparing ${INSTALL_DIR}..."
    mkdir -p "${INSTALL_DIR}"
    chmod 755 "${INSTALL_DIR}"

    info "Downloading Snck HVM..."
    TEMP_FILE="${INSTALL_DIR}/snck-hvm.download"
    rm -f "${TEMP_FILE}"
    curl --fail --location --retry 5 --retry-delay 3 \
        --connect-timeout 15 --max-time 1800 \
        --progress-bar --output "${TEMP_FILE}" "${DOWNLOAD_URL}"
    [[ -s "${TEMP_FILE}" ]] || die "HVM download failed or returned an empty file."

    FILE_TYPE="$(file -b "${TEMP_FILE}" 2>/dev/null || true)"
    if printf '%s' "${FILE_TYPE}" | grep -Eiq 'HTML|ASCII text|Unicode text|JSON'; then
        die "Downloaded file is not an executable."
    fi

    rm -f "${BIN_FILE}"
    mv "${TEMP_FILE}" "${BIN_FILE}"
    chmod 755 "${BIN_FILE}"
    chown root:root "${BIN_FILE}"
    ok "HVM executable installed."

    info "Creating systemd service..."
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Snck HVM Panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${BIN_FILE}
Restart=always
RestartSec=5
User=root
Group=root
LimitNOFILE=1048576
LimitNPROC=65535
LimitCORE=infinity
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=multi-user.target
EOF

    touch "${LOG_FILE}"
    chmod 640 "${LOG_FILE}"
    chown root:root "${LOG_FILE}"
    chmod 644 "${SERVICE_FILE}"

    if command -v ufw >/dev/null 2>&1; then ufw allow "${PANEL_PORT}/tcp" >/dev/null 2>&1 || true; fi
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${PANEL_PORT}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null
    systemctl restart "${SERVICE_NAME}"
    sleep 5

    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        ok "Snck HVM is ONLINE."
    else
        systemctl status "${SERVICE_NAME}" --no-pager --full || true
        die "Snck HVM failed to start. Check ${LOG_FILE}."
    fi

    PUBLIC_IP="$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"

    printf "\n${GREEN}${BOLD}╔════════════════════════════════════════════════════════════╗${RESET}\n"
    printf "${GREEN}${BOLD}║              SNCK HVM INSTALLED SUCCESSFULLY             ║${RESET}\n"
    printf "${GREEN}${BOLD}╚════════════════════════════════════════════════════════════╝${RESET}\n\n"
    printf "  ${CYAN}Panel URL${RESET}    : ${WHITE}http://${PUBLIC_IP}:${PANEL_PORT}${RESET}\n"
    printf "  ${CYAN}Install${RESET}      : ${WHITE}${INSTALL_DIR}${RESET}\n"
    printf "  ${CYAN}Service${RESET}      : ${WHITE}${SERVICE_NAME}${RESET}\n"
    printf "  ${CYAN}Logs${RESET}         : ${WHITE}${LOG_FILE}${RESET}\n\n"
    printf "  ${GRAY}systemctl restart ${SERVICE_NAME}${RESET}\n"
    printf "  ${GRAY}journalctl -u ${SERVICE_NAME} -f${RESET}\n\n"
}

status_hvm(){
    banner
    printf "${WHITE}${BOLD}SERVICE STATUS${RESET}\n\n"
    systemctl status "${SERVICE_NAME}" --no-pager --full || true
    printf "\n"
    read -r -p "Press Enter to return to menu..."
}

logs_hvm(){
    banner
    printf "${WHITE}${BOLD}SNCK HVM LOGS${RESET}\n\n"
    journalctl -u "${SERVICE_NAME}" -n 80 --no-pager || true
    printf "\n"
    read -r -p "Press Enter to return to menu..."
}

uninstall_hvm(){
    banner
    printf "${RED}${BOLD}UNINSTALL SNCK HVM${RESET}\n\n"
    read -r -p "Type UNINSTALL to continue: " CONFIRM
    [[ "${CONFIRM}" == "UNINSTALL" ]] || { warn "Cancelled."; sleep 1; return; }
    systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
    rm -f "${SERVICE_FILE}"
    rm -rf "${INSTALL_DIR}"
    rm -f "${LOG_FILE}"
    systemctl daemon-reload
    ok "Snck HVM has been removed."
    sleep 2
}

while true; do
    banner
    menu
    read -r -p "$(printf "${MAGENTA}${BOLD}Select an option [0-5]: ${RESET}")" choice
    case "${choice}" in
        1) install_hvm; read -r -p "Press Enter to return to menu..." ;;
        2) install_hvm; read -r -p "Press Enter to return to menu..." ;;
        3) status_hvm ;;
        4) logs_hvm ;;
        5) uninstall_hvm ;;
        0) printf "\n${CYAN}Goodbye!${RESET}\n"; exit 0 ;;
        *) printf "\n${RED}Invalid option.${RESET}\n"; sleep 1 ;;
    esac
done
