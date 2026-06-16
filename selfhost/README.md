# dangg — self-hosted Supabase on Dokploy

Self-contained Supabase stack (Postgres + Auth + REST + Realtime + Storage +
edge functions + Kong) for hosting the dangg backend on the Dokploy server at
`https://dokploy.welbuiltai.in`. Fresh DB — no data migrated from the cloud
project.

## Layout

```
selfhost/
├── genkeys.mjs            # regenerates all stack secrets (already run)
├── apply-migrations.sh    # applies the 40 dangg migrations to the fresh DB
├── sync-functions.sh      # re-copies supabase/functions → docker/volumes/functions
└── docker/                # vendored Supabase self-host stack
    ├── docker-compose.yml  # stock compose + dangg edits (SMS hook + fn secrets)
    ├── .env                # all secrets — GITIGNORED, paste into Dokploy instead
    └── volumes/functions/  # dangg's 24 edge functions + stock main router
```

dangg's edits to the stock `docker-compose.yml` (re-apply if you re-vendor a
newer Supabase): in the **auth** service — `GOTRUE_HOOK_SEND_SMS_*`; in the
**functions** service — the `APP_ENV / MYDREAMS_* / RAZORPAY_* / R2_*` block.

## Deploy on Dokploy

1. **DNS** — point `supabase.welbuiltai.in` (A record) at the server IP.
2. **Push** `selfhost/` to the git repo Dokploy pulls (`docker/.env` is
   gitignored — its values go in step 4, not git).
3. **Create a Compose service** in Dokploy → source = this repo → compose path
   `dangg-backend/selfhost/docker/docker-compose.yml`.
4. **Environment** — open the service's Environment editor and paste the full
   contents of `docker/.env` (that's where the secrets live; keep them out of
   git). It's your reference copy.
5. **Domain** — add domain `supabase.welbuiltai.in` → container **`kong`**,
   port **8000**, HTTPS on (Traefik/Let's Encrypt).
6. **Deploy.** First boot initialises Postgres + Supabase system schemas
   (~1–2 min). Needs ≥4 GB RAM.
7. **Apply dangg's schema** (once):
   ```
   DATABASE_URL='postgres://postgres:<POSTGRES_PASSWORD>@<server-ip>:5432/postgres' \
     ./apply-migrations.sh
   ```
   (or, on the server: loop the files into `docker exec -i supabase-db psql` —
   see the script header.)
8. **Seed test users** (optional, dev) — run the existing
   `scripts/seed-local-dev.mjs` against `https://supabase.welbuiltai.in`.

## Point the app at it

In `dangg-frontend/mobile/.env`:
```
SUPABASE_URL=https://supabase.welbuiltai.in
SUPABASE_ANON_KEY=<ANON_KEY — copy from docker/.env>
```
Note: self-host issues the **legacy JWT** anon key (above), *not* the
`sb_publishable_…` format the cloud project used. Rebuild the app after changing.

## OTP / Twilio note

This stack delivers OTP via the **Send SMS Hook → My Dreams Technology**
(wired in compose: `GOTRUE_HOOK_SEND_SMS_*`), so the Twilio-20003 error from the
cloud project does **not** apply here — there's no Twilio in the loop.
`APP_ENV=production` means real SMS is sent; set it to `development` (or blank
`MYDREAMS_API_KEY`) to log the OTP in the functions container logs instead.

## Studio (admin DB UI)

Reachable via the same domain; login with `DASHBOARD_USERNAME` /
`DASHBOARD_PASSWORD` from `docker/.env`. Restrict or change before exposing
publicly.

## Updating functions later

Edit under `supabase/functions/`, then `./sync-functions.sh`, commit, redeploy.
