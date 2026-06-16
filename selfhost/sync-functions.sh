#!/usr/bin/env bash
# Copy dangg's edge functions into the edge-runtime volume the stack serves.
# Re-run this whenever you change anything under supabase/functions/, then
# redeploy the Dokploy compose service (functions are read from the volume).
#
# Additive copy: the stock `main` router and `hello` example are left in place;
# function .env files are never copied (secrets come from the container env).
set -euo pipefail
SRC="$(cd "$(dirname "$0")/../supabase/functions" && pwd)/"
DST="$(cd "$(dirname "$0")/docker/volumes/functions" && pwd)/"
rsync -a \
  --exclude='.env' --exclude='.env.*' --exclude='*.test.ts' \
  "$SRC" "$DST"
echo "✅ functions synced → $DST"
