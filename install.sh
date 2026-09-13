#!/usr/bin/env bash
# Nutanix DR Automation - automated install for AlmaLinux 9
#
# Run this FROM INSIDE the extracted project directory, as root/sudo:
#   sudo bash install.sh
#
# What it does (mirrors README.md steps 1-6):
#   1. Installs python3.11, venv, firewalld
#   2. Creates the nutanix-dr service user and required directories
#   3. Copies this project into /opt/nutanix-dr-automation
#   4. Creates the venv and installs requirements
#   5. Seeds /etc/nutanix-dr/.env (from .env.example) if it doesn't exist yet
#   6. Installs and enables the two systemd services
#
# It does NOT: fill in your real credentials/IPs, or set up nginx/firewall
# rules for external access - those need a decision from you, so they're
# left as manual follow-up steps printed at the end.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo bash install.sh" >&2
  exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="/opt/nutanix-dr-automation"
ENV_DIR="/etc/nutanix-dr"
ENV_FILE="$ENV_DIR/.env"
DATA_DIR="/var/lib/nutanix-dr"
LOG_DIR="/var/log/nutanix-dr"
SVC_USER="nutanix-dr"

echo "==> [1/6] Installing prerequisites"
dnf install -y python3.11 python3.11-pip git firewalld rsync >/dev/null
systemctl enable --now firewalld >/dev/null

echo "==> [2/6] Creating service user and directories"
id -u "$SVC_USER" &>/dev/null || useradd --system --no-create-home --shell /sbin/nologin "$SVC_USER"
mkdir -p "$APP_DIR" "$ENV_DIR" "$DATA_DIR" "$LOG_DIR"
chown -R "$SVC_USER:$SVC_USER" "$DATA_DIR" "$LOG_DIR"

echo "==> [3/6] Copying project files to $APP_DIR"
# rsync keeps this safe to re-run without clobbering a live .env or state.db
rsync -a --exclude ".env" --exclude "state.db" --exclude "__pycache__" \
  "$SRC_DIR"/ "$APP_DIR"/
chown -R "$SVC_USER:$SVC_USER" "$APP_DIR"

echo "==> [4/6] Creating virtualenv and installing dependencies"
sudo -u "$SVC_USER" python3.11 -m venv "$APP_DIR/venv"
sudo -u "$SVC_USER" "$APP_DIR/venv/bin/pip" install --quiet --upgrade pip
sudo -u "$SVC_USER" "$APP_DIR/venv/bin/pip" install --quiet -r "$APP_DIR/requirements.txt"

echo "==> [5/6] Seeding environment file"
if [[ -f "$ENV_FILE" ]]; then
  echo "    $ENV_FILE already exists - leaving it untouched."
else
  cp "$APP_DIR/.env.example" "$ENV_FILE"
  chown "$SVC_USER:$SVC_USER" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "    Created $ENV_FILE from .env.example - YOU MUST EDIT THIS before starting services."
fi

echo "==> [6/6] Installing systemd services"
cp "$APP_DIR/systemd/nutanix-dr-monitor.service" /etc/systemd/system/
cp "$APP_DIR/systemd/nutanix-dr-web.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable nutanix-dr-monitor >/dev/null
systemctl enable nutanix-dr-web >/dev/null

echo
echo "=================================================================="
echo " Install steps complete. Services are ENABLED but NOT started yet."
echo "=================================================================="
echo
echo "Before starting them, you MUST:"
echo "  1. Edit $ENV_FILE with real values:"
echo "       HQ_HOST, PC_API_HOST, PC_API_USER, PC_API_PASSWORD,"
echo "       RECOVERY_PLAN_UUID (or NAME), FAILED/RECOVERY_AVAILABILITY_ZONE_URL"
echo "       -> sudo vi $ENV_FILE"
echo
echo "Then start the services:"
echo "  sudo systemctl start nutanix-dr-monitor"
echo "  sudo systemctl start nutanix-dr-web"
echo
echo "Check they're healthy:"
echo "  sudo systemctl status nutanix-dr-monitor nutanix-dr-web"
echo "  sudo journalctl -u nutanix-dr-monitor -f"
echo "  curl -I http://127.0.0.1:8080"
echo
echo "Still manual (not automated - needs your decisions):"
echo "  - nginx reverse proxy + basic auth for external dashboard access"
echo "  - firewalld rules scoping outbound access to HQ_HOST/PC_API_HOST"
echo "  See README.md sections 6-7 for exact commands."
echo "=================================================================="
