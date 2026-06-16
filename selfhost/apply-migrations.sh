#!/usr/bin/env bash
# Apply dangg's SQL migrations to the self-hosted Postgres, in filename order.
# Run ONCE after the stack's db is healthy (fresh DB, no data to migrate).
#
# Option A — from anywhere with network to the DB:
#   DATABASE_URL='postgres://postgres:<POSTGRES_PASSWORD>@<server-ip>:5432/postgres' \
#     ./apply-migrations.sh
#
# Option B — on the Dokploy server, straight into the db container:
#   for f in ../supabase/migrations/*.sql; do
#     docker exec -i supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "$f"
#   done
set -euo pipefail
MIG_DIR="$(cd "$(dirname "$0")/../supabase/migrations" && pwd)"
: "${DATABASE_URL:?Set DATABASE_URL to the self-hosted Postgres connection string}"

count=0
for f in "$MIG_DIR"/*.sql; do
  echo ">>> $(basename "$f")"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
  count=$((count + 1))
done
echo "✅ applied $count migrations"
