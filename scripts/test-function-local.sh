#!/usr/bin/env bash
# Quick curl wrapper for hitting a locally-served Edge Function.
#
# Usage:
#   ./scripts/test-function-local.sh <fn-name> [METHOD] [JSON_BODY]
#
# Examples:
#   ./scripts/test-function-local.sh config-app
#   ./scripts/test-function-local.sh send-otp POST '{"phone":"+919876543210"}'
#
# Prerequisite: run `supabase functions serve <fn-name>` in another terminal.
set -e

FN_NAME="$1"
METHOD="${2:-GET}"
BODY="$3"
URL="http://localhost:54321/functions/v1/$FN_NAME"

if [ -z "$FN_NAME" ]; then
  echo "Usage: $0 <function-name> [METHOD] [JSON_BODY]"
  exit 1
fi

if [ -z "$BODY" ]; then
  curl -i -X "$METHOD" "$URL" -H "Content-Type: application/json"
else
  curl -i -X "$METHOD" "$URL" -H "Content-Type: application/json" -d "$BODY"
fi
