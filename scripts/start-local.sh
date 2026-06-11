#!/usr/bin/env bash
# Starts the full local Supabase stack (Docker required).
#
# Sources .env first so secrets referenced from config.toml (e.g.
# SEND_SMS_HOOK_SECRET via `secrets = "env(...)"`) are available when the
# CLI validates the configuration on boot.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/.env"

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
else
  echo "⚠️  $ENV_FILE not found — copy .env.example to .env first."
fi

echo "Starting Supabase local stack..."
supabase start

echo ""
echo "Stack is up:"
echo "  Supabase Studio    http://localhost:54323"
echo "  API URL            http://localhost:54321"
echo "  Mailpit / Inbucket http://localhost:54324"
echo ""
echo "Serve Edge Functions in another terminal:"
echo "  supabase functions serve"
echo ""
echo "Stop with:  ./scripts/stop-local.sh"
