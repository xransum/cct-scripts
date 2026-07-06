#!/usr/bin/env bash
# deploy.sh
# Push one or more CC:Tweaked Lua scripts to computer(s) on a remote
# Minecraft server over SCP. The world name is read automatically from
# server.properties on the remote host so you never have to hardcode it.
#
# Usage:
#   ./deploy.sh [--host USER@HOST] [--server-dir PATH] \
#               --computer ID [--computer ID ...] \
#               FILE [FILE ...]
#
# Sensitive defaults (SSH_HOST, SERVER_DIR) are loaded from .env in the
# same directory as this script if the flags are not passed on the
# command line. See .env.example for the expected format.
#
# Examples:
#   # Use .env defaults, push both scripts to computer 9
#   ./deploy.sh --computer 9 \
#     src/resource-ticker/material_usage_monitor.lua \
#     src/resource-ticker/usage_config.lua
#
#   # Override host and dir inline, push to two computers at once
#   ./deploy.sh --host kevin@serverhub \
#               --server-dir /home/minecraft/atm10-71 \
#               --computer 9 --computer 12 \
#               src/resource-ticker/material_usage_monitor.lua

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env if present; values there are defaults, flags override them.
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
fi

SSH_HOST="${SSH_HOST:-}"
SERVER_DIR="${SERVER_DIR:-}"
COMPUTERS=()
FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)       SSH_HOST="$2";       shift 2 ;;
    --server-dir) SERVER_DIR="$2";     shift 2 ;;
    --computer)   COMPUTERS+=("$2");   shift 2 ;;
    -*)
      echo "Unknown flag: $1" >&2
      exit 1
      ;;
    *)
      FILES+=("$1")
      shift
      ;;
  esac
done

# --- Validate required params ------------------------------------------------

if [[ -z "$SSH_HOST" ]]; then
  echo "Error: SSH_HOST not set." >&2
  echo "  Pass --host USER@HOST, or add SSH_HOST=... to .env" >&2
  exit 1
fi

if [[ -z "$SERVER_DIR" ]]; then
  echo "Error: SERVER_DIR not set." >&2
  echo "  Pass --server-dir /path/to/server, or add SERVER_DIR=... to .env" >&2
  exit 1
fi

if [[ ${#COMPUTERS[@]} -eq 0 ]]; then
  echo "Error: No computer IDs specified. Use --computer ID (repeatable)." >&2
  exit 1
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "Error: No files specified." >&2
  exit 1
fi

# Verify each local file exists before touching the remote.
for f in "${FILES[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "Error: file not found: $f" >&2
    exit 1
  fi
done

# --- Detect world name from remote server.properties ------------------------

echo "Connecting to ${SSH_HOST} to read world name..."
WORLD_NAME=$(ssh "$SSH_HOST" \
  "grep '^level-name=' '${SERVER_DIR}/server.properties' | cut -d'=' -f2 | tr -d '\r\n'")

if [[ -z "$WORLD_NAME" ]]; then
  echo "Error: Could not read level-name from ${SERVER_DIR}/server.properties" >&2
  echo "  Check that SERVER_DIR is correct and server.properties exists." >&2
  exit 1
fi

echo "World: $WORLD_NAME"
echo ""

# --- Deploy to each computer -------------------------------------------------

for COMPUTER_ID in "${COMPUTERS[@]}"; do
  REMOTE_PATH="${SERVER_DIR}/${WORLD_NAME}/computercraft/computer/${COMPUTER_ID}"
  echo "Deploying to ${SSH_HOST}:${REMOTE_PATH}/"
  scp "${FILES[@]}" "${SSH_HOST}:${REMOTE_PATH}/"
done

echo ""
echo "Done."
echo ""
echo "Files deployed:"
for f in "${FILES[@]}"; do
  echo "  $(basename "$f")"
done
echo ""
echo "Runtime config files (*.cfg) were not touched."
echo "Restart the computer in-game (Ctrl+T then reboot) for changes to take effect."