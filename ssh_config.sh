#!/usr/bin/env bash
# Ubuntu Server: create user with fixed credentials, enable SSH password login,
# apply sshd config and restart/start ssh automatically (no prompts).
# Run as root: sudo bash ubuntu_add_user_ssh.sh
#
# قبل از اجرا، نام کاربری و رمز را در همین فایل مقداردهی کنید.

set -o pipefail

# ---------------------------------------------------------------------------
# تنظیمات — مقداردهی اجباری (خالی نگذارید)
# ---------------------------------------------------------------------------
NEW_USER="rd23f21"
NEW_PASSWORD="rd23f212026"
# نام فایل drop-in در sshd (فقط حروف، اعداد، خط تیره)
SSHD_DROPIN_NAME="99-local-password-login.conf"
# ---------------------------------------------------------------------------

die() { echo "Error: $*" >&2; exit 1; }

if [[ "$(id -u)" -ne 0 ]]; then
  die "Run as root, e.g.: sudo $0"
fi

[[ -n "${NEW_USER// /}" ]] || die "Edit this script: set NEW_USER (non-empty)."
[[ -n "${NEW_PASSWORD}" ]] || die "Edit this script: set NEW_PASSWORD (non-empty)."

if ! command -v sshd &>/dev/null; then
  die "openssh-server not installed. Install with: apt-get update && apt-get install -y openssh-server"
fi

SSH_UNIT=""
if systemctl cat ssh.service &>/dev/null; then
  SSH_UNIT="ssh"
elif systemctl cat sshd.service &>/dev/null; then
  SSH_UNIT="sshd"
else
  die "Neither ssh.service nor sshd.service found."
fi

SSHD_DROPIN="/etc/ssh/sshd_config.d/${SSHD_DROPIN_NAME}"

# --- user ---
if id -u "$NEW_USER" &>/dev/null; then
  echo "User '$NEW_USER' already exists; updating password only."
else
  useradd -m -s /bin/bash "$NEW_USER" || die "useradd failed for '$NEW_USER'"
  echo "Created user: $NEW_USER"
fi

if ! printf '%s:%s\n' "$NEW_USER" "$NEW_PASSWORD" | chpasswd; then
  die "chpasswd failed for '$NEW_USER'"
fi
echo "Password set for $NEW_USER"

# Grant sudo if possible (non-fatal)
if getent group sudo &>/dev/null; then
  usermod -aG sudo "$NEW_USER" 2>/dev/null && echo "Added '$NEW_USER' to group 'sudo'." || echo "Note: could not add '$NEW_USER' to sudo (ignored)."
else
  echo "Note: group 'sudo' not found (ignored)."
fi

# --- sshd: password authentication for this server ---
SSH_CONFIG_CHANGED=0

mkdir -p /etc/ssh/sshd_config.d

write_dropin() {
  umask 022
  cat > "$SSHD_DROPIN" <<EOF
# Managed by ubuntu_add_user_ssh.sh — password login (lab / initial setup)
PasswordAuthentication yes
KbdInteractiveAuthentication yes
EOF
}

effective_password_auth() {
  sshd -T 2>/dev/null | awk -F' ' 'tolower($1)=="passwordauthentication"{print tolower($2); exit}'
}

ensure_password_auth_effective() {
  local cur eff
  cur=""
  [[ -f "$SSHD_DROPIN" ]] && cur=$(sha256sum "$SSHD_DROPIN" | awk '{print $1}')

  write_dropin
  local new
  new=$(sha256sum "$SSHD_DROPIN" | awk '{print $1}')
  [[ "$cur" != "$new" ]] && SSH_CONFIG_CHANGED=1

  eff=$(effective_password_auth)
  if [[ "$eff" != "yes" ]]; then
    # اولین مقدار در فایل‌های پیکربندی غالب است؛ خطوط تکراری/غلط را یکدست می‌کنیم
    if [[ -f /etc/ssh/sshd_config ]]; then
      sed -i -E \
        's/^[#[:space:]]*PasswordAuthentication[[:space:]].*/PasswordAuthentication yes/' \
        /etc/ssh/sshd_config
      SSH_CONFIG_CHANGED=1
    fi
  fi

  eff=$(effective_password_auth)
  if [[ "$eff" != "yes" ]]; then
    echo "Warning: effective passwordauthentication is still '$eff'. Check /etc/ssh/sshd_config and Match blocks." >&2
  fi
}

ensure_password_auth_effective

if ! sshd -t 2>/dev/null; then
  echo "sshd configuration test failed:" >&2
  sshd -t >&2 || true
  die "Fix sshd_config errors above, then re-run this script."
fi

systemctl enable "$SSH_UNIT" 2>/dev/null || true

if [[ "$SSH_CONFIG_CHANGED" -eq 1 ]]; then
  systemctl restart "$SSH_UNIT" || die "systemctl restart $SSH_UNIT failed"
  echo "Restarted ${SSH_UNIT}.service (sshd configuration updated)."
elif ! systemctl is-active --quiet "$SSH_UNIT"; then
  systemctl start "$SSH_UNIT" || die "systemctl start $SSH_UNIT failed"
  echo "Started ${SSH_UNIT}.service (was inactive)."
else
  echo "SSH service already active; sshd configuration unchanged."
fi

systemctl is-active --quiet "$SSH_UNIT" || echo "Warning: ${SSH_UNIT}.service is not active; check: systemctl status $SSH_UNIT" >&2

echo "Done."
