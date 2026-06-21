# Dangg — Project Context for Claude Code

> Auto-loaded by Claude Code on every session. Keep updated as the project evolves.

## Project Summary

**Dangg** is a text-only paid chat marketplace, mobile-first (Android only for now).

- **Female users** — service providers. Earn coins by accepting and completing chats with males.
- **Male users** — buy coins via Razorpay, spend coins to send chat requests to online females.
- **Admin dashboard** — separate web app at `admin.dangg.app` for verification, payouts, analytics.

---

## Repositories

| Repo | Path | Purpose |
|---|---|---|
| `dangg-backend` | `D:\Projects_folder\SparksAI_Projects\dangg-backend` | Supabase migrations, edge functions, self-host Docker config |
| `dangg-frontend` | `D:\dangg-frontend\mobile` | React Native CLI app (Android APK) |
| `dangg` (admin) | `D:\Projects_folder\SparksAI_Projects\dangg` | Admin dashboard — Vite + React SPA |

---

## Infrastructure (Production)

| Service | URL | Notes |
|---|---|---|
| Supabase (self-hosted) | `https://dangg-db.welbuiltai.in` | Kong API gateway on port 8000 |
| Backend API | `https://api.dangg.app` | Node.js app on Dokploy |
| Admin dashboard | `https://admin.dangg.app` | Vite SPA on Dokploy |
| Dokploy (host) | `https://dokploy.welbuiltai.in` | VPS control panel |
| Cloudflare | — | DNS + proxy for all domains |

### Dokploy Service IDs

| Service | ID |
|---|---|
| Project (DANGG) | `lAFjERvtgQtmYzcqxNOuk` |
| Mobile App Backend | `mtCUbENh2Cry-PzyW4eu8` |
| Supabase compose | `7dULIrfqduWx_0LvdOcyA` |
| Admin Panel app | `qu62w3Bvl3uNYlKIrY9ry` |
| Environment (production) | `amkISOBbXAEFIWQ109m7A` |

### Supabase Self-Host Critical Notes

- Compose path: `./selfhost/docker/docker-compose.yml`
- GoTrue SMS hook URI: `https://dangg-db.welbuiltai.in/functions/v1/send-sms-hook` — **NOT** `api.dangg.app`
- Edge functions are at `dangg-db.welbuiltai.in/functions/v1/...` (not api.dangg.app)
- `compose.deploy` = full redeploy (re-reads env + compose file)
- `compose.stop` + `compose.start` = restart only (does NOT re-read env)
- After every `compose.deploy`, GoTrue gets a DB networking error — must do stop/start after deploy
- To update env vars in running containers: full redeploy required

---

## Tech Stack

### Mobile App (React Native)

| Layer | Choice |
|---|---|
| Framework | React Native CLI (bare workflow) |
| Language | TypeScript (strict mode) |
| State | Zustand + subscribeWithSelector |
| Navigation | React Navigation v7 (native stack + tabs) |
| Forms | React Hook Form + Zod |
| Animation | React Native Reanimated 3 |
| Auth | Supabase Auth — OTP phone login via SMS |
| SMS | MSG91 via Supabase Send SMS Hook (edge function) |
| Payments | Razorpay (`react-native-razorpay`) |
| Push | Firebase Cloud Messaging (`@react-native-firebase/messaging`) |
| Images | Cloudinary (CDN) + Supabase Storage (private verification photos) |
| Realtime | Supabase Realtime (online status, chat requests) |
| Secure storage | `react-native-keychain` (session/refresh tokens) |
| Fast KV | `react-native-mmkv` |
| Env vars | `react-native-config` — baked into APK at build time |

**Firebase Auth is NOT used.** Firebase is present only for FCM push delivery.

### Backend / Supabase

| Layer | Choice |
|---|---|
| Database | PostgreSQL (via Supabase self-hosted) |
| Auth | GoTrue (Supabase Auth) |
| API | PostgREST (REST auto-generated from schema) |
| Edge Functions | Deno (TypeScript) |
| Storage | Supabase Storage (Mumbai region) |
| Realtime | Supabase Realtime |

### Admin Dashboard

| Layer | Choice |
|---|---|
| Framework | Vite + React 19 SPA |
| Routing | React Router DOM v7 |
| Styling | Tailwind CSS |
| Animation | Framer Motion |
| Auth | Hardcoded credentials in `src/lib/auth.js` (localStorage) |
| DB access | Supabase JS client with service role key (runtime injected) |

---

## Authentication Flow (Mobile)

1. User enters phone number
2. `supabase.auth.signInWithOtp({ phone })` → GoTrue calls Send SMS Hook
3. Hook calls MSG91 API → OTP SMS delivered
4. User enters OTP → `supabase.auth.verifyOtp({ phone, token, type: 'sms' })`
5. Supabase issues JWT → stored in Keychain via custom `supabaseAuthStorage`
6. All DB calls use JWT; RLS enforces per-user access

---

## Key Database Tables

```
users          — shared profile (id = auth.uid(), name, phone, role, age)
males          — coin_balance, total_coins_purchased, chats_initiated
females        — verification_status, is_online, earnings_balance_coins
coin_packages  — id, coins, price_paisa, is_active
chat_sessions  — status, started_at, ended_at, male_id, female_id
chat_messages  — session_id, sender_id, content, sent_at
payments       — amount_paisa, status (captured = successful)
payouts        — payout_amount_paisa, status, requested_at
payout_details — upi_id, account_number, method
notifications  — user_id, type, payload
fcm_tokens     — user_id, token, platform
waitlist_users — email, phone, name, gender (landing page signups — Phase 2)
```

Monetary values are stored in **paisa** (1/100 rupee). Always convert: `paisa / 100` = rupees.

---

## Key RPCs (PostgreSQL Functions)

| Function | Returns | Purpose |
|---|---|---|
| `male_wallet_snapshot()` | `jsonb` | `coinBalance`, `totalCoinsPurchased`, `chatsStarted` for current male |
| `get_female_verification_status(p_phone)` | row | Verification status for female login |
| `verify_current_password(p_password)` | bool | Password check before update |

---

## Building the Android APK

```powershell
cd D:\dangg-frontend\mobile\android
.\gradlew assembleRelease
# Output: app\build\outputs\apk\release\app-release.apk
```

- `.env` values (especially `SUPABASE_URL`) are baked in at build time via `react-native-config`
- After any URL/env change → must rebuild APK
- If build fails with locked dirs: `Remove-Item -Recurse -Force app\build\intermediates\...`

---

## Admin Dashboard Deployment

- Repo: `D:\Projects_folder\SparksAI_Projects\dangg` → GitHub: `rohithbab/dangg`
- Deployed via Dokploy (app ID `qu62w3Bvl3uNYlKIrY9ry`) — auto-deploys on push to `main`
- Secrets injected at **container runtime** via `entrypoint.sh` (not build time)
- Env vars set in Dokploy Environment tab: `VITE_SUPABASE_URL`, `VITE_SUPABASE_SERVICE_KEY`
- Admin login: hardcoded in `src/lib/auth.js` — `admin@danggapp` / `Admin@Danggapp2026`

---

## Phase Status

| Feature | Status |
|---|---|
| Sign-up / login / OTP | ✅ Done |
| Male home — browse females | ✅ Done |
| Chat request send/receive | ✅ Done |
| Coin purchase (Razorpay) | ✅ Done |
| Female verification flow | ✅ Done |
| Payout request flow | ✅ Done |
| Admin dashboard (read-only) | ✅ Done |
| Active chat (text/image) | ⏳ Phase 2 |
| Coin deduction during chat | ⏳ Phase 2 |
| Landing page + waitlist | ⏳ Phase 2 |
| Admin waitlist stats page | ⏳ Phase 2 |

---

## Development Conventions

- **One issue at a time.** No broad sweeping changes.
- **Analyze before implementing.** For bugs: diagnose and report first, then code after confirmation.
- **TypeScript strict mode.** Zero `any` unless documented with `// @ts-expect-error: <reason>`.
- **No comments** unless the WHY is non-obvious (hidden constraint, workaround, subtle invariant).
- **Monetary values** — always store in paisa, display in rupees via `formatRupees(paisa)`.
- **Never commit `.env` files.** Secrets go in Dokploy environment config only.

---

## Environment Variables

### Mobile app (`dangg-frontend/mobile/.env` — never commit)

```
SUPABASE_URL=https://dangg-db.welbuiltai.in
SUPABASE_ANON_KEY=<anon key>
CLOUDINARY_CLOUD_NAME=<name>
RAZORPAY_KEY_ID=<key>
DEV_MODE=false
APP_ENV=production
```

### Admin dashboard (set in Dokploy — never in repo)

```
VITE_SUPABASE_URL=https://dangg-db.welbuiltai.in
VITE_SUPABASE_SERVICE_KEY=<service role key>
```
