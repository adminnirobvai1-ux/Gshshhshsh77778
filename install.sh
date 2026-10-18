#!/usr/bin/env bash

#  ======================================================
#  PUFFERPANEL UNIVERSAL INSTALLER (E2B EDITION)
#  Modified for E2B Sandbox (Debian Trixie + Auto Tunnel)
#  ======================================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

BANNER='\n  ╭──────────────────────────────────────────────╮\n  │          PufferPanel E2B Installer           │\n  │     PufferPanel + Docker + PM2 + Tunnel      │\n  ╰──────────────────────────────────────────────╯\n'

printf "${CYAN}%b${NC}\n" "$BANNER"

SUDO=""
if [[ ${EUID} -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo -e "${RED}[ERROR] Run as root or install sudo.${NC}"
    exit 1
  fi
fi

log() { echo -e "${CYAN}[*]${NC} $1"; }
ok() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1"; }

print_card() {
  local title="$1"
  echo -e "${BLUE}╭──────────────────────────────────────────────╮${NC}"
  printf "${BLUE}│${NC} %-44s ${BLUE}│${NC}\n" "$title"
  echo -e "${BLUE}╰──────────────────────────────────────────────╯${NC}"
}

random_string() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1" || echo "AdminPass12345"
}

pkg_installed() {
  dpkg -s "$1" >/dev/null 2>&1
}

cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

apt_fix() {
  ${SUDO} rm -f /etc/apt/sources.list.d/pufferpanel.list 2>/dev/null || true
  ${SUDO} dpkg --configure -a || true
  ${SUDO} apt --fix-broken install -y || true
  ${SUDO} apt update -y || true
}

ensure_pkg() {
  local pkg="$1"
  if pkg_installed "$pkg"; then
    ok "$pkg already installed"
    return 0
  fi
  if ${SUDO} apt install -y "$pkg"; then
    ok "$pkg installed"
    return 0
  fi
  warn "Retrying $pkg after apt fix..."
  apt_fix
  ${SUDO} apt install -y "$pkg" || warn "Could not install $pkg"
}

ensure_base_packages() {
  print_card "Base packages"
  # software-properties-common removed as it breaks on Debian Trixie
  local packages=(curl wget gnupg ca-certificates lsb-release apt-transport-https procps)
  for pkg in "${packages[@]}"; do
    ensure_pkg "$pkg" || true
  done
}

ensure_docker() {
  print_card "Docker Setup (E2B VFS Mode)"
  if ! cmd_exists docker; then
    ensure_pkg docker.io || true
  else
    ok "Docker binary already installed"
  fi

  set +u
  if docker info >/dev/null 2>&1; then
    ok "Docker daemon already running"
    set -u
    return 0
  fi

  log "Starting Docker in VFS mode for E2B..."
  ${SUDO} pkill -9 dockerd 2>/dev/null || true
  ${SUDO} rm -f /var/run/docker.sock /var/run/docker.pid 2>/dev/null || true
  ${SUDO} nohup dockerd --storage-driver=vfs --iptables=false >/tmp/dockerd.vfs.log 2>&1 &

  for i in {1..10}; do
    sleep 1
    printf "."
    docker info >/dev/null 2>&1 && break
  done
  echo

  if docker info >/dev/null 2>&1; then
    ok "Docker started successfully"
  else
    warn "Docker daemon could not start (E2B kernel restriction), continuing..."
  fi
  set -u
}

ensure_node_pm2() {
  print_card "Node.js + PM2"
  if cmd_exists pm2; then
    ok "PM2 already installed"
    return 0
  fi

  if ! cmd_exists node || ! cmd_exists npm; then
    log "Installing Node.js..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | ${SUDO} bash - || true
    ensure_pkg nodejs || true
  fi

  if cmd_exists npm; then
    log "Installing PM2 globally..."
    ${SUDO} npm install -g pm2 && ok "PM2 installed"
  fi
}

setup_pufferpanel_repo() {
  print_card "PufferPanel Repository (Debian Fix)"
  # Clean broken repo from previous run
  ${SUDO} rm -f /etc/apt/sources.list.d/pufferpanel.list 2>/dev/null || true

  log "Adding PufferPanel Debian Bookworm repo..."
  curl -fsSL https://packagecloud.io/pufferpanel/pufferpanel/gpgkey | ${SUDO} gpg --dearmor --yes -o /usr/share/keyrings/pufferpanel-archive-keyring.gpg || true
  
  # E2B runs Debian Trixie; Bookworm repo is compatible and stable
  echo "deb [signed-by=/usr/share/keyrings/pufferpanel-archive-keyring.gpg] https://packagecloud.io/pufferpanel/pufferpanel/debian/ bookworm main" | ${SUDO} tee /etc/apt/sources.list.d/pufferpanel.list >/dev/null
  
  ${SUDO} apt update -y || true
}

ensure_pufferpanel() {
  print_card "PufferPanel Install"
  if cmd_exists pufferpanel; then
    ok "PufferPanel already installed"
  else
    setup_pufferpanel_repo
    ensure_pkg pufferpanel || true
  fi

  ${SUDO} mkdir -p /etc/pufferpanel /var/lib/pufferpanel /var/log/pufferpanel
  ${SUDO} chown -R "$(whoami)" /etc/pufferpanel /var/lib/pufferpanel /var/log/pufferpanel 2>/dev/null || true
}

create_admin_user() {
  print_card "Admin User Creation"
  
  # Reading from /dev/tty so bash <(curl ...) doesn't skip input!
  echo -n "Enter admin username (default: admin): "
  read -r ADMIN_USER </dev/tty || ADMIN_USER="admin"
  ADMIN_USER="${ADMIN_USER:-admin}"

  echo -n "Enter admin email (default: admin@e2b.dev): "
  read -r ADMIN_EMAIL </dev/tty || ADMIN_EMAIL="admin@e2b.dev"
  ADMIN_EMAIL="${ADMIN_EMAIL:-admin@e2b.dev}"

  echo -n "Enter admin password (leave blank for random): "
  read -r INPUT_PASS </dev/tty || INPUT_PASS=""
  if [[ -z "${INPUT_PASS}" ]]; then
    ADMIN_PASS=$(random_string 12)
  else
    ADMIN_PASS="$INPUT_PASS"
  fi

  log "Creating PufferPanel admin user..."
  if ${SUDO} pufferpanel user add --name "$ADMIN_USER" --email "$ADMIN_EMAIL" --password "$ADMIN_PASS" --admin >/tmp/pufferpanel-user-add.log 2>&1; then
    ok "Admin user created successfully"
  else
    warn "User might already exist or check /tmp/pufferpanel-user-add.log"
  fi
}

setup_pm2() {
  print_card "Starting PufferPanel via PM2"
  if ! cmd_exists pm2; then
    warn "PM2 not found, starting PufferPanel in background with nohup"
    ${SUDO} nohup pufferpanel run >/tmp/pufferpanel.log 2>&1 &
    return 0
  fi

  ${SUDO} pm2 delete pufferpanel 2>/dev/null || true
  if ${SUDO} pm2 start "$(command -v pufferpanel)" --name pufferpanel -- run; then
    ok "PufferPanel started with PM2"
  else
    ${SUDO} pm2 start "$(command -v pufferpanel)" --name pufferpanel -- runService || true
  fi
  ${SUDO} pm2 save || true
}

setup_cloudflare_tunnel() {
  print_card "Public URL Tunnel (Cloudflare)"
  if ! cmd_exists cloudflared; then
    log "Installing Cloudflared..."
    curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb
    ${SUDO} dpkg -i /tmp/cloudflared.deb >/dev/null 2>&1 || ${SUDO} apt install -f -y
  fi

  log "Generating public link for port 8080..."
  ${SUDO} pkill -f "cloudflared tunnel" 2>/dev/null || true
  nohup cloudflared tunnel --url http://localhost:8080 >/tmp/cf_tunnel.log 2>&1 &

  PUBLIC_URL=""
  for i in {1..15}; do
    sleep 1
    printf "."
    PUBLIC_URL=$(grep -o 'https://[-a-z0-9]*\.trycloudflare\.com' /tmp/cf_tunnel.log | head -n 1 || true)
    if [[ -n "$PUBLIC_URL" ]]; then
      break
    fi
  done
  echo

  if [[ -n "$PUBLIC_URL" ]]; then
    ok "Public URL created: $PUBLIC_URL"
  else
    warn "Could not fetch tunnel URL automatically. Run: cat /tmp/cf_tunnel.log"
    PUBLIC_URL="http://localhost:8080 (Run tunnel manually)"
  fi
}

main() {
  print_card "Cleaning & Updating System"
  apt_fix
  ensure_base_packages
  ensure_docker
  ensure_node_pm2
  ensure_pufferpanel
  create_admin_user
  setup_pm2
  setup_cloudflare_tunnel

  print_card "Install Complete (E2B Ready)"
  echo -e "${GREEN}PufferPanel is now running!${NC}"
  echo
  echo -e "Public URL : ${CYAN}${PUBLIC_URL}${NC}"
  echo -e "Username   : ${YELLOW}${ADMIN_USER}${NC}"
  echo -e "Email      : ${YELLOW}${ADMIN_EMAIL}${NC}"
  echo -e "Password   : ${YELLOW}${ADMIN_PASS}${NC}"
  echo -e "Docker     : $(docker --version 2>/dev/null || echo unavailable)"
  echo -e "PM2        : $(pm2 --version 2>/dev/null || echo unavailable)"
  echo
  echo -e "${GREEN}Tip: Open the Public URL above in your phone browser to login!${NC}"
}

main "$@"
