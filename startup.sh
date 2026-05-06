#!/bin/bash
set -e

PORT=8080

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

# 2. Ensure GitHub CLI is installed
if ! command -v gh &> /dev/null; then
    log "Installing GitHub CLI..."
    sudo apt update && sudo apt install -y gh
fi

# 3. Authenticate GitHub CLI using the Codespace token
if ! gh auth status &> /dev/null; then
    log "Authenticating GitHub CLI with GITHUB_TOKEN..."
    echo "${GITHUB_TOKEN}" | gh auth login --with-token --hostname github.com
else
    log "GitHub CLI already authenticated."
fi

# 4. Check if chisel is installed or install it
if ! command -v chisel &> /dev/null; then
    log "Chisel not found. Installing from GitHub..."
    sudo curl -L https://github.com/jpillora/chisel/releases/download/v1.9.1/chisel_1.9.1_linux_amd64.gz | gunzip | sudo tee /usr/local/bin/chisel > /dev/null
    sudo chmod +x /usr/local/bin/chisel
fi

# 5. Start chisel SOCKS5 proxy if not already running on PORT
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

# 6. Make the port publicly accessible on the current Codespace
log "Making port $PORT public via GitHub CLI..."
# We explicitly pass the Codespace name if necessary, or let gh default to the current connected codespace
gh codespace ports visibility "$PORT:public" --codespace "$CODESPACE_NAME" || error "Failed to set port visibility"

# 7. Retrieve and display the public URL
get_public_url() {
    gh codespace ports list --codespace "$CODESPACE_NAME" --jq ".[] | select(.sourcePort==$PORT) | .browseUrl"
}

URL=$(get_public_url)
if [ -z "$URL" ]; then
    log "Waiting for URL propagation..."
    sleep 3
    URL=$(get_public_url)
fi

if [ -n "$URL" ]; then
    echo "🎉 Port $PORT is publicly accessible at: $URL"
else
    log "Could not retrieve URL. Check manually with: gh codespace ports list"
fi
