#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# SNCK HVM — INSTALLER
# ============================================================

APP_NAME="Snck HVM"
SERVICE_NAME="snck-hvm"
INSTALL_DIR="/opt/snck-hvm"
BIN_FILE="${INSTALL_DIR}/snck-hvm"
LOG_FILE="/var/log/snck-hvm.log"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# Replace this URL with your real license API endpoint.
LICENSE_API="${SNCK_LICENSE_API:-https://official.snck.fun/api/v1/license/validate}"
PANEL_PORT="${SNCK_PANEL_PORT:-8080}"

# Original HKVM v2 executable URL supplied in the uploaded project.
# This keeps the installer source-compatible with the supplied package,
# but the downloaded executable itself is NOT rebranded.
DOWNLOAD_URL="${SNCK_HVM_DOWNLOAD_URL:-https://files.catbox.moe/k9nizi}"

RED='\e[1;31m'; GREEN='\e[1;32m'; YELLOW='\e[1;33m'
CYAN='\e[1;36m'; MAGENTA='\e[1;35m'; WHITE='\e[1;37m'; NC='\e[0m'

info(){ echo -e "${CYAN}[INFO]${NC} $*"; }
ok(){ echo -e "${GREEN}[OK]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARNING]${NC} $*"; }
die(){ echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
line(){ echo -e "${MAGENTA}============================================================${NC}"; }

cleanup(){ rm -f "${INSTALL_DIR}/snck-hvm.download" 2>/dev/null || true; }
trap cleanup EXIT

clear 2>/dev/null || true
echo -e "${CYAN}"
cat <<'EOF'
   _____ _   _  _____ _  __
  / ____| \ | |/ ____| |/ /
 | (___ |  \| | |    | ' /
  \___ \| . ` | |    |  <
  ____) | |\  | |____| . \
 |_____/|_| \_|\_____|_|\_\

             SNCK HVM
        CLOUD VM PANEL INSTALLER
EOF
echo -e "${NC}"
line

[[ "${EUID}" -eq 0 ]] || die "Run this installer as root."

info "Installing required dependencies..."
export DEBIAN_FRONTEND=noninteractive

if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y qemu-system cloud-image-utils wget curl ca-certificates file iproute2 lsof procps sudo
else
    die "This installer currently supports Debian/Ubuntu systems with apt-get."
fi
ok "Dependencies installed."

line

# License gate.
# The server must return HTTP 2xx and JSON containing {"valid":true}.
# No license is stored in the repository.
read -r -p "Enter your Snck HVM license: " SNCK_LICENSE
[[ -n "${SNCK_LICENSE}" ]] || die "A license is required."

info "Validating Snck HVM license..."
LICENSE_RESPONSE="$(curl -fsS --max-time 15 \
    -H 'Accept: application/json' \
    --get "${LICENSE_API}" \
    --data-urlencode "license=${SNCK_LICENSE}" \
    --data-urlencode "product=snck-hvm" \
    || true)"

if ! printf '%s' "${LICENSE_RESPONSE}" | grep -Eq '"valid"[[:space:]]*:[[:space:]]*true'; then
    die "License validation failed. Check the license and ${LICENSE_API}."
fi
ok "License accepted."

line

info "Preparing ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"
chmod 755 "${INSTALL_DIR}"

info "Downloading HVM executable..."
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

line

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
    ok "Snck HVM service is ONLINE."
else
    systemctl status "${SERVICE_NAME}" --no-pager --full || true
    die "Snck HVM failed to start. Check ${LOG_FILE}."
fi

PUBLIC_IP="$(curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"

line
echo -e "${GREEN}"
cat <<EOF
╔════════════════════════════════════════════════════════════╗
║                  SNCK HVM INSTALLED                        ║
╚════════════════════════════════════════════════════════════╝

  Panel URL         : http://${PUBLIC_IP}:${PANEL_PORT}
  Install directory : ${INSTALL_DIR}
  Service           : ${SERVICE_NAME}
  Log               : ${LOG_FILE}

  Start             : systemctl start ${SERVICE_NAME}
  Stop              : systemctl stop ${SERVICE_NAME}
  Restart           : systemctl restart ${SERVICE_NAME}
  Status            : systemctl status ${SERVICE_NAME}
  Logs              : journalctl -u ${SERVICE_NAME} -f
EOF
echo -e "${NC}"
line
ok "Snck HVM installation finished."
