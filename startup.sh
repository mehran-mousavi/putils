#!/usr/bin/env bash
set -Eeuo pipefail

PORT="${PORT:-8080}"
SSH_LOGIN_USER="${SSH_LOGIN_USER:-root}"
SSH_PASSWORD_ENV_VAR="${SSH_PASSWORD_ENV_VAR:-SSH_ROOT_PASSWORD}"
STARTUP_LOCK_DIR="${STARTUP_LOCK_DIR:-/tmp/putils-startup.lock}"
CHISEL_LOG="${CHISEL_LOG:-/tmp/chisel.log}"
GH_TIMEOUT_SECONDS="${GH_TIMEOUT_SECONDS:-20}"
CHISEL_DOWNLOAD_TIMEOUT_SECONDS="${CHISEL_DOWNLOAD_TIMEOUT_SECONDS:-120}"
export GH_PROMPT_DISABLED=1

log() {
    echo "putils-startup: $1"
}

warn() {
    echo "putils-startup warning: $1" >&2
}

acquire_lock() {
    if mkdir "$STARTUP_LOCK_DIR" 2>/dev/null; then
        trap 'rmdir "$STARTUP_LOCK_DIR" 2>/dev/null || true' EXIT
        return
    fi

    log "Startup is already running. Skipping this invocation."
    exit 0
}

run_with_timeout() {
    local seconds="$1"
    shift

    if command -v timeout &> /dev/null; then
        timeout "$seconds" "$@"
    else
        "$@"
    fi
}

# 1. Verify we are running inside a Codespace
if [ -z "${CODESPACE_NAME:-}" ]; then
    warn "Not running inside Codespaces. Skipping startup actions."
    exit 0
fi

acquire_lock

# 2. Configure SSH login credentials (root + password from env var)
configure_ssh_credentials() {
    local ssh_login_password="${!SSH_PASSWORD_ENV_VAR:-}"

    if [ "$SSH_LOGIN_USER" != "root" ]; then
        warn "SSH_LOGIN_USER is '${SSH_LOGIN_USER}', expected 'root'. Skipping SSH password setup."
    elif [ -z "$ssh_login_password" ]; then
        warn "Missing ${SSH_PASSWORD_ENV_VAR}. Set it as a Codespaces secret/environment variable."
    else
        echo "${SSH_LOGIN_USER}:${ssh_login_password}" | sudo chpasswd
        log "SSH login configured for user '${SSH_LOGIN_USER}' using password from ${SSH_PASSWORD_ENV_VAR}."
    fi
}

configure_gh_auth() {
    if ! command -v gh &> /dev/null; then
        warn "GitHub CLI (gh) is missing. Rebuild the Codespace to install the github-cli feature."
        return
    fi

    local gh_token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

    if run_with_timeout "$GH_TIMEOUT_SECONDS" gh auth status --hostname github.com &> /dev/null; then
        log "GitHub CLI is authenticated."
    elif [ -n "$gh_token" ]; then
        log "Authenticating GitHub CLI using token from environment..."
        if printf '%s\n' "$gh_token" | run_with_timeout "$GH_TIMEOUT_SECONDS" gh auth login --with-token --hostname github.com; then
            log "GitHub CLI authenticated successfully."
        else
            warn "GitHub CLI authentication failed. Port visibility updates may be skipped."
        fi
    else
        warn "GitHub CLI is not authenticated. Port visibility updates may be skipped."
    fi
}

install_chisel_if_missing() {
    if ! command -v chisel &> /dev/null; then
        local chisel_url="https://github.com/jpillora/chisel/releases/download/v1.11.5/chisel_1.11.5_linux_amd64.gz"
        local tmp_file

        if ! command -v curl &> /dev/null || ! command -v gunzip &> /dev/null; then
            warn "curl or gunzip is missing. Cannot install Chisel."
            return
        fi

        log "Chisel not found. Installing from GitHub..."
        tmp_file="$(mktemp)"
        if curl -fsSL --connect-timeout 10 --max-time "$CHISEL_DOWNLOAD_TIMEOUT_SECONDS" "$chisel_url" | gunzip > "$tmp_file"; then
            sudo install -m 0755 "$tmp_file" /usr/local/bin/chisel
            rm -f "$tmp_file"
            log "Chisel installed successfully."
        else
            rm -f "$tmp_file"
            warn "Chisel installation failed. Continuing."
        fi
    fi
}

check_port_active() {
    ss -ltn | grep -qE "(^|[[:space:]]|:)$PORT[[:space:]]"
}

start_chisel() {
    log "Starting Chisel SOCKS5 server on port $PORT..."
    nohup chisel server --socks5 --port "$PORT" > "$CHISEL_LOG" 2>&1 &
    local pid=$!
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        log "Chisel server started with PID $pid"
    else
        warn "Chisel server failed to start. Check $CHISEL_LOG"
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
        run_with_timeout "$GH_TIMEOUT_SECONDS" gh codespace ports visibility "$PORT:public" --codespace "$CODESPACE_NAME" || warn "Failed to set port visibility."
    else
        warn "Skipping port visibility update because gh is unavailable."
    fi
}

get_published_url() {
    run_with_timeout "$GH_TIMEOUT_SECONDS" gh codespace ports list --codespace "$CODESPACE_NAME" --jq ".[] | select(.sourcePort==$PORT) | (.publicUrl // .browseUrl)" 2>/dev/null || true
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
            echo "Published URL for port $PORT: $URL"
        else
            log "Could not retrieve published URL. Check manually with: gh codespace ports list --codespace \"$CODESPACE_NAME\""
        fi
    fi
}


configure_ssh_credentials
configure_gh_auth
install_chisel_if_missing
publish_chisel_port
show_published_url
