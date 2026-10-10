#!/usr/bin/env bash
# SNCK HVM / NRB Panel installer for the actual Flask + Socket.IO project.
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

REPO="https://github.com/SnckBoy/Snck-hvm"
ARCHIVE_URL="https://raw.githubusercontent.com/SnckBoy/Snck-hvm/main/nrb2.zip"
ROOT="/opt/snck-hvm"
APP="$ROOT/app"
ENV_FILE="/etc/snck-hvm.env"
SERVICE="snck-hvm"
UNIT="/etc/systemd/system/$SERVICE.service"
LOG="/var/log/snck-hvm-installer.log"
BACKUPS="/var/backups/snck-hvm"
PORT="${SNCK_HVM_PORT:-5000}"

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
die(){ log "ERROR: $*"; exit 1; }
pause(){ read -r -p $'\nPress Enter to continue...' _ || true; }
need_root(){ [[ $EUID -eq 0 ]] || die "Run as root: sudo bash install.sh"; }
have(){ command -v "$1" >/dev/null 2>&1; }

install_system_packages(){
  [[ -f /etc/os-release ]] || die "Cannot identify OS."
  . /etc/os-release
  case "${ID:-}" in ubuntu|debian) ;; *) die "Supported systems: Ubuntu and Debian."; esac
  export DEBIAN_FRONTEND=noninteractive
  log "Installing system dependencies..."
  apt-get update
  apt-get install -y ca-certificates curl unzip tar python3 python3-venv python3-pip python3-dev build-essential libffi-dev libssl-dev docker.io socat openssl
  systemctl enable --now docker
  # Compose is optional for the panel itself; package names differ across apt sources.
  apt-get install -y docker-compose-v2 >/dev/null 2>&1 || apt-get install -y docker-compose-plugin >/dev/null 2>&1 || true
}

backup_existing(){
  [[ -d "$APP" ]] || return 0
  mkdir -p "$BACKUPS"
  local out="$BACKUPS/snck-hvm-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar --exclude='./venv' --exclude='./__pycache__' -czf "$out" -C "$ROOT" app
  log "Existing app backed up to $out"
}

fetch_and_extract(){
  local tmp src
  tmp="$(mktemp -d)"
  log "Downloading panel archive..."
  if ! curl -fL --retry 3 --connect-timeout 20 "$ARCHIVE_URL" -o "$tmp/panel.zip"; then
    rm -rf "$tmp"
    die "Download failed. Check VPS network and repository archive URL."
  fi
  unzip -tq "$tmp/panel.zip" >/dev/null || { rm -rf "$tmp"; die "Downloaded ZIP is corrupt."; }
  mkdir -p "$tmp/unpacked" "$APP"
  unzip -q "$tmp/panel.zip" -d "$tmp/unpacked"
  src="$(find "$tmp/unpacked" -type f -name nrb.py -not -path '*/__pycache__/*' -print -quit)"
  [[ -n "$src" ]] || { rm -rf "$tmp"; die "Could not find nrb.py inside the ZIP. Expected NRB/nrb.py."; }
  src="$(dirname "$src")"
  [[ -f "$src/requirements.txt" ]] || { rm -rf "$tmp"; die "requirements.txt is missing beside nrb.py."; }
  [[ -f "$src/start.sh" ]] || log "Note: start.sh not found; service will launch nrb.py directly."
  log "Found Python panel source at $src"
  # Never install the archive's bundled development database or bytecode.
  # Preserve the live database and uploads on updates.
  find "$src" -mindepth 1 -maxdepth 1 ! -name nrb.db ! -name __pycache__ ! -name venv -exec cp -a -t "$APP" -- {} +
  rm -rf "$tmp"
  [[ -f "$APP/nrb.py" && -f "$APP/requirements.txt" ]] || die "Panel files did not land in $APP."
  # The published archive references activate_license.html from nrb.py but
  # omits that template. Add it during install so /activate-license won't 500.
  mkdir -p "$APP/templates"
  if [[ ! -f "$APP/templates/activate_license.html" ]]; then
    cat > "$APP/templates/activate_license.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Activate {{ panel_name|default('NRB PANEL') }}</title>
  <style>
    *{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px;background:#0c111b;color:#eef2ff;font:16px system-ui,-apple-system,sans-serif}
    main{width:min(100%,440px);padding:30px;border:1px solid #293449;border-radius:20px;background:#121a28;box-shadow:0 24px 80px #0006}
    h1{margin:0 0 8px;font-size:26px}p{color:#aebbd0;line-height:1.55}.hint{font-size:13px}
    label{display:block;margin:22px 0 8px;font-weight:600}input,button{width:100%;border-radius:10px;padding:13px;font:inherit}
    input{background:#0b1220;color:#fff;border:1px solid #34425a}button{margin-top:14px;border:0;background:#3978f6;color:#fff;font-weight:700;cursor:pointer}
    #message{min-height:24px;color:#ffb4b4;font-size:14px}button:disabled{opacity:.6}
  </style>
</head>
<body>
<main>
  <h1>Activate {{ panel_name|default('NRB PANEL') }}</h1>
  <p>Enter the license key supplied by your panel administrator to continue.</p>
  <form id="license-form" method="post" action="{{ url_for('activate_license_submit') }}">
    <label for="license_key">License key</label>
    <input id="license_key" name="license_key" type="password" autocomplete="off" required>
    <button id="submit" type="submit">Activate license</button>
    <p id="message" role="status" aria-live="polite"></p>
  </form>
  <p class="hint">If you do not have a license key, contact the provider of this panel.</p>
</main>
<script>
document.getElementById('license-form').addEventListener('submit', async function(event) {
  event.preventDefault();
  const button = document.getElementById('submit');
  const message = document.getElementById('message');
  button.disabled = true; message.textContent = 'Checking license…';
  try {
    const response = await fetch(this.action, {
      method: 'POST',
      body: new FormData(this),
      headers: {'X-Requested-With': 'XMLHttpRequest'}
    });
    const data = await response.json();
    if (response.ok && data.success) {
      message.style.color = '#86efac';
      message.textContent = 'License activated. Opening panel…';
      window.location.href = '/login';
    } else {
      message.style.color = '#ffb4b4';
      message.textContent = data.error || 'License activation failed.';
    }
  } catch (error) {
    message.textContent = 'Request failed. Please try again.';
  } finally {
    button.disabled = false;
  }
});
</script>
</body>
</html>
HTML
    log "Added missing templates/activate_license.html (archive omitted this required template)."
  fi
  find "$APP" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
  chmod +x "$APP/start.sh" "$APP/nrb-tool.sh" 2>/dev/null || true
  log "Source files installed into $APP"
}

prepare_environment(){
  mkdir -p "$APP" "$BACKUPS"
  if [[ ! -f "$ENV_FILE" ]]; then
    # Older generic-installer attempts may have copied the repository's bundled
    # development database. Keep a copy, but don't silently deploy its accounts.
    if [[ -f "$APP/nrb.db" ]] && ! systemctl cat "$SERVICE" >/dev/null 2>&1; then
      local dbbackup="$BACKUPS/preinstall-database-$(date +%Y%m%d-%H%M%S).db"
      cp -a "$APP/nrb.db" "$dbbackup"
      rm -f "$APP/nrb.db" "$APP/nrb.db-wal" "$APP/nrb.db-shm"
      log "Moved pre-existing database to $dbbackup so a fresh admin account can be created."
    fi
    local admin_pass secret
    admin_pass="$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')"
    secret="$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')"
    cat > "$ENV_FILE" <<EOF
HOST=0.0.0.0
PORT=$PORT
DEBUG_MODE=False
PANEL_NAME="SNCK HVM"
SECRET_KEY=$secret
MAIN_ADMIN_USERNAME=admin
MAIN_ADMIN_PASSWORD=$admin_pass
MAIN_ADMIN_EMAIL=admin@localhost
DATABASE_PATH=nrb.db
EOF
    chmod 600 "$ENV_FILE"
    printf '\nINITIAL_ADMIN_USERNAME=admin\nINITIAL_ADMIN_PASSWORD=%s\n' "$admin_pass" > "$ROOT/INITIAL-ADMIN-CREDENTIALS.txt"
    chmod 600 "$ROOT/INITIAL-ADMIN-CREDENTIALS.txt"
    log "Generated a unique admin password; it will be shown at the end of installation."
  else
    log "Keeping existing environment settings in $ENV_FILE"
  fi
}

setup_python(){
  log "Preparing Python virtual environment and dependencies..."
  python3 -m venv "$APP/venv"
  "$APP/venv/bin/python" -m pip install --upgrade pip
  "$APP/venv/bin/python" -m pip install -r "$APP/requirements.txt"
  "$APP/venv/bin/python" -m py_compile "$APP/nrb.py" "$APP/docker_backend.py" "$APP/api.py"
}

write_service(){
  id snckhvm >/dev/null 2>&1 || useradd --system --home-dir "$ROOT" --shell /usr/sbin/nologin snckhvm
  getent group docker >/dev/null 2>&1 || groupadd docker
  usermod -aG docker snckhvm
  chown -R snckhvm:snckhvm "$ROOT"
  [[ ! -f "$ROOT/INITIAL-ADMIN-CREDENTIALS.txt" ]] || chown root:root "$ROOT/INITIAL-ADMIN-CREDENTIALS.txt"
  chmod 600 "$ENV_FILE"
  cat > "$UNIT" <<EOF
[Unit]
Description=SNCK HVM Panel (Flask + Socket.IO)
Wants=network-online.target docker.service
After=network-online.target docker.service

[Service]
Type=simple
User=snckhvm
Group=snckhvm
SupplementaryGroups=docker
WorkingDirectory=$APP
EnvironmentFile=$ENV_FILE
Environment=PYTHONUNBUFFERED=1
ExecStart=$APP/venv/bin/python $APP/nrb.py
Restart=on-failure
RestartSec=5
TimeoutStartSec=90
UMask=0027

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE"
}

install_panel(){
  need_root
  install_system_packages
  backup_existing
  fetch_and_extract
  prepare_environment
  setup_python
  write_service
  systemctl restart "$SERVICE" || systemctl start "$SERVICE"
  sleep 2
  if systemctl is-active --quiet "$SERVICE"; then
    log "Panel service is running."
  else
    log "Service did not stay up. Recent logs:"
    journalctl -u "$SERVICE" -n 80 --no-pager || true
    die "Installation completed but the app failed to start. Use menu option 7 for logs."
  fi
  log "Installer finished. Check port $PORT and firewall/security-group rules."
  if [[ -f "$ROOT/INITIAL-ADMIN-CREDENTIALS.txt" ]]; then
    echo
    echo "===== INITIAL ADMIN LOGIN (save this now) ====="
    cat "$ROOT/INITIAL-ADMIN-CREDENTIALS.txt"
    echo "==============================================="
    echo "Credentials file: $ROOT/INITIAL-ADMIN-CREDENTIALS.txt (root-only)"
  fi
}

start_panel(){ systemctl start "$SERVICE"; systemctl --no-pager --full status "$SERVICE" || true; }
stop_panel(){ systemctl stop "$SERVICE"; log "Service stopped."; }
restart_panel(){ systemctl restart "$SERVICE"; systemctl --no-pager --full status "$SERVICE" || true; }
status_panel(){ systemctl --no-pager --full status "$SERVICE" || true; echo; ss -ltnp | grep -E ":$PORT\b" || true; }
logs_panel(){ journalctl -u "$SERVICE" -n 120 --no-pager || true; }
backup_panel(){
  [[ -d "$APP" ]] || { echo "Panel is not installed."; return 1; }
  mkdir -p "$BACKUPS"
  local out="$BACKUPS/manual-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar --exclude='./venv' --exclude='./__pycache__' -czf "$out" -C "$ROOT" app
  cp -a "$ENV_FILE" "$out.env"
  chmod 600 "$out" "$out.env"
  log "Backup saved to $out and $out.env"
}
system_info(){
  . /etc/os-release
  echo "OS: $PRETTY_NAME"
  echo "Kernel: $(uname -r) / $(uname -m)"
  echo "Python: $(python3 --version 2>&1)"
  echo "Docker: $(docker --version 2>&1 || true)"
  echo "App: $APP"
  echo "Port: $PORT"
  echo "Service: $(systemctl is-active "$SERVICE" 2>/dev/null || echo not-installed)"
  df -h "$ROOT" 2>/dev/null || df -h /
  free -h 2>/dev/null || true
}
uninstall_panel(){
  echo "This removes the service and application, but keeps backups in $BACKUPS."
  read -r -p "Type REMOVE to confirm: " confirm
  [[ "$confirm" == REMOVE ]] || { echo "Cancelled."; return; }
  systemctl disable --now "$SERVICE" 2>/dev/null || true
  rm -f "$UNIT"
  systemctl daemon-reload
  rm -rf "$ROOT" "$ENV_FILE"
  id snckhvm >/dev/null 2>&1 && userdel snckhvm || true
  log "Application removed. Backups in $BACKUPS were kept."
}

menu(){
  while true; do
    clear 2>/dev/null || true
    cat <<'MENU'
╔══════════════════════════════════════════════════╗
║             SNCK HVM PANEL MANAGER              ║
╚══════════════════════════════════════════════════╝
 1) Install / Repair
 2) Update (backup + install latest source)
 3) Start panel
 4) Stop panel
 5) Restart panel
 6) Status / listening port
 7) Logs
 8) Backup panel + environment
 9) System information
10) Uninstall
 0) Exit
MENU
    read -r -p "Choose [0-10]: " choice || break
    case "$choice" in
      1) install_panel || true; pause ;;
      2) install_panel || true; pause ;;
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
mkdir -p "$(dirname "$LOG")"
touch "$LOG"
menu
