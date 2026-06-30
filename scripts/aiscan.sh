#!/bin/bash
set -euo pipefail

TMAS_BIN="${TMAS_BIN:-./tmas}"
APP_ENDPOINT="http://k8s-default-aidocana-3ba5b16aee-1c414a31de8690bb.elb.us-east-1.amazonaws.com"
CONFIG_FILE="ai-doc-analyzer-aiscan.yaml"

if [[ -z "${TMAS_API_KEY:-}" ]]; then
  echo "Error: TMAS_API_KEY environment variable is not set."
  echo "Usage: TMAS_API_KEY=<your-key> ./scripts/aiscan.sh"
  exit 1
fi

echo "AI Doc Analyzer — AI Scanner"
echo "Endpoint : $APP_ENDPOINT"
echo "Config   : $CONFIG_FILE"
echo ""

if [[ -f "$CONFIG_FILE" ]]; then
  echo "Found existing config: $CONFIG_FILE"
  read -rp "Re-run with saved config? [Y/n] " choice
  choice="${choice:-Y}"
  if [[ "$choice" =~ ^[Yy]$ ]]; then
    exec "$TMAS_BIN" --region=ap-southeast-2 --config "$CONFIG_FILE"
  fi
fi

echo "Starting interactive scan setup..."
echo "When prompted:"
echo "  - Endpoint URL : $APP_ENDPOINT"
echo "  - Scan group   : ai-doc-analyzer"
echo "  - Model name   : ai-doc-analyzer-api"
echo "  - Save config  : $CONFIG_FILE"
echo ""

exec "$TMAS_BIN" aiscan llm --interactive --region=ap-southeast-2
