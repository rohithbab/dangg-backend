#!/usr/bin/env bash
# Drops and recreates the local Postgres database, re-running every
# migration and the seed file. DESTRUCTIVE.
set -e

read -rp "This will DELETE all local data. Continue? (y/N) " confirm
if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
  echo "Cancelled."
  exit 0
fi

supabase db reset
node scripts/seed-local-dev.mjs
echo "Database reset complete."
