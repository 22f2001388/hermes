#!/usr/bin/env bash
# Local per-agent launcher: ./run.sh <agent> [up|down|logs|build]
set -euo pipefail

RAW_NAME="${1:-primary}"
ACTION="${2:-up}"

# Lowercase so casing can't split an agent's state/prefix (matches hermes-sync.py).
AGENT_NAME="$(printf '%s' "$RAW_NAME" | tr '[:upper:]' '[:lower:]')"
export AGENT_NAME

PROJECT="hermes-${AGENT_NAME}"

case "$ACTION" in
up) exec docker compose -p "$PROJECT" up --build ;;
build) exec docker compose -p "$PROJECT" build ;;
down) exec docker compose -p "$PROJECT" down ;;
logs) exec docker compose -p "$PROJECT" logs -f ;;
*)
	echo "FATAL: unknown action '$ACTION' (use up|down|logs|build)" >&2
	exit 1
	;;
esac
