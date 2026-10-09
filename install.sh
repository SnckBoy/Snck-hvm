#!/usr/bin/env bash
# Snck-hvm installer and manager
# Extracts the repository's bundled nrb2.zip and manages a detected web app.
set -Eeuo pipefail
IFS=$'\n\t'

REPO="https://github.com/SnckBoy/Snck-hvm"
ARCHIVE_URL="https://raw.githubusercontent.com/SnckBoy/Snck-hvm/main/nrb2.zip"
APP_ROOT="/opt/snck-hvm"
APP_DIR="$APP_ROOT/app"
STATE_DIR="/var/lib/snck-hvm"
SERVICE="snck-hvm"
SERVICE_FILE="/etc/systemd/system/$SERVICE.service"
LOG_FILE="/var/log/snck-hvm-installer.log"
PORT="${SNCK_HVM_PORT:-8080}"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "Run as root: sudo bash install.sh"; }
have() { command -v "$1" >/dev/null 2>&1; }
pause() { read -r -p $'\nPress Enter to continue...' _ || true; }

detect_app() {
  if [[ -f "$APP_DIR/package.json" ]]; then echo node
  elif [[ -f "$APP_DIR/requirements.txt" ]] || [[ -f "$APP_DIR/app.py" ]] || [[ -f "$APP_DIR/main.py" ]]; then echo python
  elif [[ -f "$APP_DIR/composer.json" ]] || [[ -f "$APP_DIR/index.php" ]]; then echo php
  elif [[ -f "$APP_DIR/index.html" ]]; then echo static
  else echo unknown
  fi
}

install_packages() {
  have apt-get || die "This installer currently supports Ubuntu/Debian (apt-get)."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl unzip tar git
}

extract_archive() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  log "Downloading panel archive from $REPO"
  curl --fail --location --retry 3 --connect-timeout 20 "$ARCHIVE_URL" -o "$tmp/panel.zip"
  unzip -tq "$tmp/panel.zip" >/dev/null || die "Downloaded archive is invalid."
  mkdir -p "$APP_ROOT"
  if [[ -d "$APP_DIR" ]]; then
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    tar -czf "$APP_ROOT/backup-before-update-$stamp.tar.gz" -C "$APP_ROOT" app
    rm -rf "$APP_DIR"
  fi
  mkdir -p "$APP_DIR"
  unzip -q "$tmp/panel.zip" -d "$tmp/extracted"
  # Copy the archive's contents without assuming its internal top-level folder.
  local first
  first="$(find "$tmp/extracted" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)"
  if [[ -n "$first" ]] && [[ "$(find "$tmp/extracted" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]]; then
    cp -a "$first"/. "$APP_DIR"/
  else
    cp -a "$tmp/extracted"/. "$APP_DIR"/
  fi
  [[ -n "$(find "$APP_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die "Archive extracted no files."
  log "Archive extracted to $APP_DIR"
}

setup_runtime() {
  local kind
  kind="$(detect_app)"
  log "Detected project type: $kind"
  case "$kind" in
    node)
      apt-get install -y nodejs npm
      if [[ -f "$APP_DIR/package-lock.json" ]]; then (cd "$APP_DIR" && npm ci)
      else (cd "$APP_DIR" && npm install); fi
      ;;
    python)
      apt-get install -y python3 python3-venv python3-pip
      python3 -m venv "$APP_DIR/.venv"
      if [[ -f "$APP_DIR/requirements.txt" ]]; then "$APP_DIR/.venv/bin/pip" install -r "$APP_DIR/requirements.txt"; fi
      ;;
    php)
      apt-get install -y php-cli php-curl php-mbstring php-xml php-zip
      if [[ -f "$APP_DIR/composer.json" ]]; then
        apt-get install -y composer
        (cd "$APP_DIR" && composer install --no-interaction --prefer-dist)
      fi
      ;;
    static)
      apt-get install -y python3
      ;;
    unknown)
      log "No supported app manifest detected. Files are extracted; service was not created."
      log "Inspect $APP_DIR and add the correct runtime/start command before enabling a service."
      return 2
      ;;
  esac
  return 0
}

write_service() {
  local kind="$1" start_cmd=""
  case "$kind" in
    node)
      start_cmd="/usr/bin/npm start"
      ;;
    python)
      if [[ -f "$APP_DIR/app.py" ]]; then start_cmd="$APP_DIR/.venv/bin/python $APP_DIR/app.py"
      elif [[ -f "$APP_DIR/main.py" ]]; then start_cmd="$APP_DIR/.venv/bin/python $APP_DIR/main.py"
      else die "Python requirements found but no app.py/main.py entrypoint. Configure the service manually."; fi
      ;;
    php)
      if [[ -f "$APP_DIR/index.php" ]]; then start_cmd="/usr/bin/php -S 0.0.0.0:$PORT -t $APP_DIR"
      else die "PHP manifest found but no index.php. Configure the service manually."; fi
      ;;
    static)
      start_cmd="/usr/bin/python3 -m http.server $PORT --bind 0.0.0.0 --directory $APP_DIR"
      ;;
    *) die "Unsupported app type: $kind" ;;
  esac

  id snckhvm >/dev/null 2>&1 || useradd --system --home-dir "$APP_ROOT" --shell /usr/sbin/nologin snckhvm
  chown -R snckhvm:snckhvm "$APP_ROOT"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Snck-hvm Panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=snckhvm
Group=snckhvm
WorkingDirectory=$APP_DIR
Environment=NODE_ENV=production
Environment=PORT=$PORT
ExecStart=$start_cmd
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$SERVICE"
  log "Service enabled and started. Check logs/status from the menu."
}

install_panel() {
  install_packages
  extract_archive
  local kind
  kind="$(detect_app)"
  setup_runtime || return 2
  write_service "$kind"
  log "Install complete. Panel directory: $APP_DIR"
  log "Configured port: $PORT (verify the app actually uses this port)."
}

update_panel() {
  [[ -d "$APP_DIR" ]] || { log "Not installed yet."; return 1; }
  install_panel
}

start_panel() { systemctl start "$SERVICE"; log "Start requested."; }
stop_panel() { systemctl stop "$SERVICE"; log "Stop requested."; }
restart_panel() { systemctl restart "$SERVICE"; log "Restart requested."; }
status_panel() { systemctl status "$SERVICE" --no-pager || true; }
logs_panel() { journalctl -u "$SERVICE" -n 100 --no-pager || true; }
backup_panel() {
  [[ -d "$APP_DIR" ]] || { log "No installed app directory to back up."; return 1; }
  mkdir -p "$STATE_DIR/backups"
  local out="$STATE_DIR/backups/snck-hvm-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar -czf "$out" -C "$APP_ROOT" app
  log "Backup saved: $out"
}
system_info() {
  echo "OS: $(. /etc/os-release && echo "$PRETTY_NAME")"
  echo "Kernel: $(uname -r)"
  echo "Architecture: $(uname -m)"
  echo "App directory: $APP_DIR"
  echo "Project type: $(detect_app)"
  echo "Port setting: $PORT"
  df -h "$APP_ROOT" 2>/dev/null || df -h /
  free -h 2>/dev/null || true
}
uninstall_panel() {
  echo "This removes the service and app files under $APP_ROOT."
  echo "Backups under $STATE_DIR are kept."
  read -r -p "Type REMOVE to confirm: " confirm
  [[ "$confirm" == "REMOVE" ]] || { echo "Cancelled."; return; }
  systemctl disable --now "$SERVICE" 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload
  rm -rf "$APP_ROOT"
  id snckhvm >/dev/null 2>&1 && userdel snckhvm || true
  log "Service and app files removed. State/backups, if any, were not intentionally deleted."
}

menu() {
  while true; do
    clear 2>/dev/null || true
    cat <<'MENU'
╔══════════════════════════════════════╗
║       SNCK HVM PANEL MANAGER         ║
╚══════════════════════════════════════╝
 1) Install / extract panel
 2) Update panel (backup + extract)
 3) Start service
 4) Stop service
 5) Restart service
 6) Status
 7) View logs
 8) Create backup
 9) System information
10) Uninstall panel
 0) Exit
MENU
    read -r -p "Choose [0-10]: " choice || break
    case "$choice" in
      1) install_panel || true; pause ;;
      2) update_panel || true; pause ;;
      3) start_panel || true; pause ;;
      4) stop_panel || true; pause ;;
      5) restart_panel || true; pause ;;
      6) status_panel; pause ;;
      7) logs_panel; pause ;;
      8) backup_panel || true; pause ;;
      9) system_info; pause ;;
      10) uninstall_panel; pause ;;
      0) exit 0 ;;
      *) echo "Invalid choice."; pause ;;
    esac
  done
}

need_root
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
menu
