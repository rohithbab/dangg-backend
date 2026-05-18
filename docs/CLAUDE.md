# Dangg — Project Context for Claude Code

> This file is read automatically by Claude Code on every session. Keep it updated as the project evolves.

## Project Summary

**Dangg** is a text-only paid chat marketplace, mobile-first.

- **Female users** are service providers. They earn by chatting with paying males.
- **Male users** buy coins, spend coins to send chat requests to online females.
- **Admin** (separate web dashboard) manages verification, payouts, and disputes.

## Phase 1 vs Phase 2

| Area | Phase 1 (now) | Phase 2 (later) |
|---|---|---|
| Sign-up, login, OTP | ✅ | — |
| Profile management | ✅ | — |
| Browsing available females | ✅ | — |
| Sending chat requests | ✅ | — |
| Incoming request popup (female) | ✅ | — |
| Accept/decline (female) | ✅ | — |
| **Active chat** (text/image/video) | ❌ | ✅ |
| Queue management (5-person, 20-min) | ❌ | ✅ |
| Coin deduction during chat | ❌ | ✅ |
| Like/dislike rating screen (UI only) | ✅ | — |
| Payout flow | ✅ | — |
| Admin dashboard | ✅ (web, separate repo) | — |

Phase 2 chat experience is intentionally deferred.

## Tech Stack

| Layer | Choice | Reasoning |
|---|---|---|
| Mobile framework | **React Native CLI** (bare workflow) | Full native control for Razorpay, Vision Camera, FCM |
| Language | **TypeScript** (strict mode) | Type safety end-to-end |
| State management | **Zustand** | Lightweight, TS-friendly, no boilerplate |
| Navigation | **React Navigation v7** (native stack + tabs) | Typed route params, native screens for performance |
| Forms | **React Hook Form** + **Zod** | Minimal re-renders, schema validation |
| Animation | **React Native Reanimated 3** | UI-thread worklets, smooth animations |
| Backend | **Supabase** (`ap-south-1`, Mumbai) | Auth + Postgres + Storage + Realtime + Edge Functions |
| Supabase client | **@supabase/supabase-js** + `react-native-url-polyfill` | Standard JS SDK |
| Auth | **Supabase Auth** with custom SMS hook | OTP-based phone login |
| SMS provider | **MSG91** | Cheap Indian SMS via Supabase Send SMS Hook |
| Image hosting | **Cloudinary** | CDN, transformations, free tier 25GB |
| Sensitive photos | **Supabase Storage** (private, Mumbai region) | DPDP compliance for verification photos |
| Payments | **Razorpay** (`react-native-razorpay`) | Coin purchases, webhook-driven credit |
| Push notifications | **@react-native-firebase/messaging** | Android standard; iOS via APNs |
| Real-time | **Supabase Realtime** | Online status, incoming chat requests, notifications |
| Secure storage | **react-native-keychain** | Session tokens, refresh tokens |
| Fast key-value | **react-native-mmkv** | Prefs and caches (10× faster than AsyncStorage) |
| Image rendering | **react-native-fast-image** | Cached remote images |
| Camera | **react-native-vision-camera** | Verification photo capture |
| Permissions | **react-native-permissions** | Camera, gallery, notifications |
| Connectivity | **@react-native-community/netinfo** | Offline state |
| Date/time | **date-fns** | Tree-shakable, lightweight |
| Lists | **@shopify/flash-list** | High-performance virtualized lists |
| HTTP client | **Supabase SDK** (primary) + native `fetch` for Cloudinary | — |
| Env vars | **react-native-config** | Native-readable, build-time injection |
| Testing | **Jest** + **React Native Testing Library** | Standard |
| Linting | **ESLint** + **Prettier** (strict) | — |

**Firebase Auth is NOT used.** Firebase is present only via `@react-native-firebase/messaging` for FCM push delivery.

## Architecture Diagram

```
                  ┌─────────────────────────┐
                  │  React Native CLI App   │
                  │   (iOS + Android, TS)   │
                  └────────────┬────────────┘
                               │
            ┌──────────────────┼──────────────────┐
            │                  │                  │
            ▼                  ▼                  ▼
   ┌─────────────────┐ ┌──────────────┐ ┌──────────────┐
   │    Supabase     │ │  Cloudinary  │ │     FCM      │
   │  (ap-south-1)   │ │   (CDN)      │ │  (push only) │
   │                 │ └──────────────┘ └──────────────┘
   │  - Auth         │
   │  - Postgres DB  │
   │  - Storage      │──────► Verification photos (private)
   │  - Realtime     │
   │  - Edge Funcs   │
   └────────┬────────┘
            │
   ┌────────┼────────┐
   │        │        │
   ▼        ▼        ▼
 ┌─────┐ ┌─────┐ ┌──────────┐
 │MSG91│ │Razor│ │  Admin   │
 │(SMS)│ │ pay │ │Dashboard │
 └─────┘ └─────┘ │(separate)│
                 └──────────┘
```

## Authentication Flow

1. User enters mobile number.
2. App calls `supabase.auth.signInWithOtp({ phone })`.
3. Supabase generates OTP → invokes Send SMS Hook (Edge Function `send-sms-hook`).
4. Hook calls MSG91 API → SMS delivered.
5. User enters OTP.
6. App calls `supabase.auth.verifyOtp({ phone, token, type: 'sms' })`.
7. Supabase issues JWT → stored via `react-native-keychain`.
8. All subsequent calls use JWT; Postgres RLS enforces per-user access.

## Repository Layout

```
dangg/
├── mobile/                  # React Native CLI app (this repo's focus)
├── supabase/                # Backend (separate repo)
└── admin-dashboard/         # Web admin panel (separate repo)
```

- Detailed folder structure: see [`PROJECT_STRUCTURE.md`](./PROJECT_STRUCTURE.md)
- API endpoints: see [`API_REFERENCE.md`](./API_REFERENCE.md)
- Screen specs: see [`mobile_app_screen_spec.md`](./mobile_app_screen_spec.md)

## Development Workflow Conventions

- **Branch strategy:** `develop` (integration), feature branches off `develop`, `main` (production).
- **One issue at a time.** No broad sweeping changes.
- **Analysis before implementation.** Bugs: analyze and report first; await confirmation; then code.
- **Verification checkpoints.** End-of-task: produce a checklist of done + skipped.
- **TypeScript strict mode.** Zero `any` unless documented with `// @ts-expect-error: <reason>`.
- **ESLint zero warnings.** Pre-commit hook enforces.

## Environment Variables (`.env` — never commit)

```
# Supabase
SUPABASE_URL=
SUPABASE_ANON_KEY=

# Cloudinary
CLOUDINARY_CLOUD_NAME=

# Razorpay
RAZORPAY_KEY_ID=

# FCM
FCM_PROJECT_ID=

# App
DEV_MODE=false                     # true bypasses real OTP during development
APP_ENV=development                # development | staging | production
```

Backend-only secrets (service role, webhook secrets, MSG91 auth key, Razorpay key secret) live in the Supabase repo, never in the mobile app.

## Code Style (enforced)

- 2-space indentation
- Single quotes (JSX attrs use double)
- Semicolons required
- Trailing commas (multi-line)
- Line length soft cap 100 chars
- No default exports except screens and React Navigation route configs
- Components: `PascalCase.tsx` (e.g., `PrimaryButton.tsx`)
- Hooks: `useCamelCase.ts` (e.g., `useDebounce.ts`)
- Folders: `camelCase` (e.g., `chatRequests/`)
- Constants: `UPPER_SNAKE_CASE` for module-level immutables

## Open Design Decisions

- [ ] Coin deduction model: per-minute vs per-message vs flat
- [ ] Chat session duration cap
- [ ] Hard vs soft delete on chat transcripts (admin)
- [ ] Refund policy for disconnected chats
- [ ] Female photo retake permissions after verification
- [ ] Admin: shared login vs multi-admin with audit trail
- [ ] Coin package final prices

## Compliance Checklist (DPDP Act 2023)

- [ ] Privacy Policy + Terms of Service drafted and linked in About App
- [ ] Explicit consent at verification photo upload
- [ ] Verification photos stored in `ap-south-1` (Mumbai)
- [ ] Data retention policy documented
- [ ] User-initiated data export endpoint
- [ ] User-initiated data deletion endpoint
- [ ] Audit log on admin actions
