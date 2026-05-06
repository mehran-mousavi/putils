#!/bin/bash
set -e

PORT=8080
SSH_LOGIN_USER="${SSH_LOGIN_USER:-root}"
SSH_PASSWORD_ENV_VAR="SSH_ROOT_PASSWORD"

log() {
    echo "🔧 $1"
}

error() {
    echo "❌ $1" >&2
    exit 1
}

# 1. Verify we are running inside a Codespace
if [ -z "$CODESPACE_NAME" ] || [ -z "$GITHUB_TOKEN" ]; then
    error "This script must be run inside an active GitHub Codespace."
fi

# 2. Ensure GitHub CLI is available from devcontainer feature
if ! command -v gh &> /dev/null; then
    error "GitHub CLI (gh) is missing. Rebuild the Codespace to install the github-cli feature."
fi

# 3. Configure SSH login credentials (root + password from env var)
SSH_LOGIN_PASSWORD="${!SSH_PASSWORD_ENV_VAR:-}"
if [ "$SSH_LOGIN_USER" != "root" ]; then
    error "This setup expects SSH_LOGIN_USER=root to match sshd feature behavior."
fi
if [ -z "$SSH_LOGIN_PASSWORD" ]; then
    error "Missing ${SSH_PASSWORD_ENV_VAR}. Set it as a Codespaces secret/environment variable."
fi
echo "${SSH_LOGIN_USER}:${SSH_LOGIN_PASSWORD}" | sudo chpasswd
log "SSH login configured for user '${SSH_LOGIN_USER}' using password from ${SSH_PASSWORD_ENV_VAR}."

# 4. Authenticate GitHub CLI using the Codespace token
if ! gh auth status &> /dev/null; then
    log "Authenticating GitHub CLI with GITHUB_TOKEN..."
    echo "${GITHUB_TOKEN}" | gh auth login --with-token --hostname github.com
else
    log "GitHub CLI already authenticated."
fi

# 5. Install Google Chrome for desktop-lite if missing
if ! command -v google-chrome &> /dev/null; then
    log "Installing Google Chrome..."
    sudo apt-get update
    sudo bash -c "export DEBIAN_FRONTEND=noninteractive && curl -sSL https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -o /tmp/chrome.deb && apt-get -y install /tmp/chrome.deb"
else
    log "Google Chrome already installed."
fi

# 6. Check if chisel is installed or install it
if ! command -v chisel &> /dev/null; then
    log "Chisel not found. Installing from GitHub..."
    sudo curl -L https://github.com/jpillora/chisel/releases/download/v1.11.5/chisel_1.11.5_linux_amd64.gz | gunzip | sudo tee /usr/local/bin/chisel > /dev/null
    sudo chmod +x /usr/local/bin/chisel
fi

# 7. Start chisel SOCKS5 proxy if not already running on PORT
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
        error "Chisel server failed to start. Check /tmp/chisel.log"
    fi
}

if check_port_active; then
    log "Port $PORT already in use. Skipping Chisel startup."
else
    start_chisel
fi

# 8. Make the port publicly accessible on the current Codespace
log "Making port $PORT public via GitHub CLI..."
# We explicitly pass the Codespace name if necessary, or let gh default to the current connected codespace
gh codespace ports visibility "$PORT:public" --codespace "$CODESPACE_NAME" || error "Failed to set port visibility"

# 9. Retrieve and display the published public URL
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

URL=$(wait_for_published_url || true)
if [ -n "$URL" ]; then
    echo "🎉 Published URL for port $PORT: $URL"
else
    log "Could not retrieve published URL. Check manually with: gh codespace ports list --codespace \"$CODESPACE_NAME\""
fi
