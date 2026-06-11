#!/usr/bin/env bash
# Deploys a single Edge Function to the linked Supabase project.
#
# Usage: ./scripts/deploy-function.sh <function-name>
#
# Prerequisite: `supabase link --project-ref <ref>` has been run once.
set -e

FN_NAME="$1"
if [ -z "$FN_NAME" ]; then
  echo "Usage: $0 <function-name>"
  echo "Example: $0 config-app"
  exit 1
fi

supabase functions deploy "$FN_NAME"
