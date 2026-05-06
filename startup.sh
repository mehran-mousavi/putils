#!/bin/bash
set -euo pipefail

PORT=8080
SSH_LOGIN_USER="${SSH_LOGIN_USER:-root}"
SSH_PASSWORD_ENV_VAR="SSH_ROOT_PASSWORD"
LOCK_FILE="/tmp/putils-startup.lock"

log() {
    echo "🔧 $1"
}

warn() {
    echo "⚠️ $1" >&2
}

# 1. Verify we are running inside a Codespace
if [ -z "${CODESPACE_NAME:-}" ]; then
    warn "Not running inside Codespaces. Skipping startup actions."
    exit 0
fi

# 2. Configure SSH login credentials (root + password from env var)
configure_ssh_credentials() {
    SSH_LOGIN_PASSWORD="${!SSH_PASSWORD_ENV_VAR:-}"
    if [ "$SSH_LOGIN_USER" != "root" ]; then
        warn "SSH_LOGIN_USER is '${SSH_LOGIN_USER}', expected 'root'. Skipping SSH password setup."
    elif [ -z "$SSH_LOGIN_PASSWORD" ]; then
        warn "Missing ${SSH_PASSWORD_ENV_VAR}. Set it as a Codespaces secret/environment variable."
    else
        echo "${SSH_LOGIN_USER}:${SSH_LOGIN_PASSWORD}" | sudo chpasswd
        log "SSH login configured for user '${SSH_LOGIN_USER}' using password from ${SSH_PASSWORD_ENV_VAR}."
    fi
}

configure_gh_auth() {
    if ! command -v gh &> /dev/null; then
        warn "GitHub CLI (gh) is missing. Rebuild the Codespace to install the github-cli feature."
        return
    fi
    if [ -n "${GITHUB_TOKEN:-}" ] && ! gh auth status &> /dev/null; then
        log "Authenticating GitHub CLI with GITHUB_TOKEN..."
        echo "${GITHUB_TOKEN}" | gh auth login --with-token --hostname github.com || warn "GitHub CLI authentication failed. Continuing."
    else
        log "GitHub CLI already authenticated."
    fi
}

install_chisel_if_missing() {
    if ! command -v chisel &> /dev/null; then
        log "Chisel not found. Installing from GitHub..."
        if sudo curl -fsSL https://github.com/jpillora/chisel/releases/download/v1.11.5/chisel_1.11.5_linux_amd64.gz | gunzip | sudo tee /usr/local/bin/chisel > /dev/null; then
            sudo chmod +x /usr/local/bin/chisel
        else
            warn "Chisel installation failed. Continuing."
        fi
    fi
}

check_port_active() {
    ss -lpn | grep -q ":$PORT"
}

start_chisel() {
    log "Starting Chisel SOCKS5 server on port $PORT..."
    nohup chisel server --socks5 --port "$PORT" > /tmp/chisel.log 2>&1 &
    local pid=$!
    sleep 2
    if kill -0 $pid 2>/dev/null; then
        log "Chisel server started with PID $pid"
    else
        warn "Chisel server failed to start. Check /tmp/chisel.log"
    fi
}

publish_chisel_port() {
    if ! command -v chisel &> /dev/null; then
        warn "Chisel is unavailable, skipping SOCKS5 startup and publish."
        return
    fi
    if check_port_active; then
        log "Port $PORT already in use. Skipping Chisel startup."
    else
        start_chisel
    fi
    if command -v gh &> /dev/null; then
        log "Making port $PORT public via GitHub CLI..."
        gh codespace ports visibility "$PORT:public" --codespace "$CODESPACE_NAME" || warn "Failed to set port visibility."
    else
        warn "Skipping port visibility update because gh is unavailable."
    fi
}

get_published_url() {
    gh codespace ports list --codespace "$CODESPACE_NAME" --jq ".[] | select(.sourcePort==$PORT) | (.publicUrl // .browseUrl)"
}

wait_for_published_url() {
    local attempts=5
    local delay_seconds=2
    local published_url=""

    for ((i=1; i<=attempts; i++)); do
        published_url=$(get_published_url)
        if [ -n "$published_url" ]; then
            echo "$published_url"
            return 0
        fi

        log "Waiting for URL propagation... ($i/$attempts)"
        sleep "$delay_seconds"
    done

    return 1
}

show_published_url() {
    if command -v gh &> /dev/null; then
        URL=$(wait_for_published_url || true)
        if [ -n "$URL" ]; then
            echo "🎉 Published URL for port $PORT: $URL"
        else
            log "Could not retrieve published URL. Check manually with: gh codespace ports list --codespace \"$CODESPACE_NAME\""
        fi
    fi
}

# Avoid overlapping runs from multiple attach events.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    warn "Startup is already running; skipping duplicate invocation."
    exit 0
fi

configure_ssh_credentials
configure_gh_auth
install_chisel_if_missing
publish_chisel_port
show_published_url
