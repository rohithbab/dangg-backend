# Dangg Backend

Supabase-hosted backend for Dangg — a text-only paid chat marketplace.
Postgres + Auth + Storage + Realtime + Edge Functions, all in one stack.

For project context, tech-stack rationale, and conventions, read [`docs/CLAUDE.md`](./docs/CLAUDE.md).
For the complete endpoint inventory, see [`docs/DANGG_BACKEND_API_INVENTORY.md`](./docs/DANGG_BACKEND_API_INVENTORY.md).

## Tech stack

- **Postgres 15** (managed by Supabase)
- **Supabase Auth** with custom SMS hook → MSG91
- **Supabase Storage** for sensitive photos (private bucket)
- **Supabase Realtime** for chat requests, presence, notifications
- **Supabase Edge Functions** — Deno + TypeScript strict
- **Zod** for runtime input validation
- **Razorpay** for payments
- **Cloudinary** for non-sensitive media
- **FCM** for push notifications

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) — required for the local Supabase stack
- Node 20+ (only for the Supabase CLI install)
- [Supabase CLI](https://supabase.com/docs/guides/cli) — `npm install -g supabase`
- [Deno](https://deno.land) 2.x — for Edge Function formatting / linting / type-checking
- git

## First-time setup

```bash
# 1. Clone the repo
git clone <repo-url> dangg-backend
cd dangg-backend

# 2. Bootstrap env file (left blank; fill as services come online)
cp .env.example .env

# 3. Start the local stack (downloads Docker images on first run — ~5 min)
./scripts/start-local.sh

# 4. Copy the printed anon + service_role keys into .env

# 5. Sanity check
deno task verify
```

When the stack is up:

| URL | Purpose |
|---|---|
| http://localhost:54321 | API base (PostgREST + Auth + Functions) |
| http://localhost:54323 | Supabase Studio (DB browser, SQL editor) |
| http://localhost:54324 | Inbucket — captures OTPs / emails locally |

## Daily workflow

```bash
# Start the stack at the beginning of the day
./scripts/start-local.sh

# Develop a new migration
supabase migration new <descriptive_name>
# ...edit the generated SQL file...
supabase db reset   # re-applies every migration locally

# Develop an Edge Function
supabase functions serve <function-name>      # hot-reloads on save
./scripts/test-function-local.sh <function-name>

# Format / lint / typecheck before committing
deno task verify

# Stop the stack at end of day (data persists)
./scripts/stop-local.sh
```

## Useful commands

| Command | Purpose |
|---|---|
| `./scripts/start-local.sh` | Start local Supabase stack |
| `./scripts/stop-local.sh` | Stop local Supabase stack |
| `./scripts/reset-db.sh` | Drop and recreate local DB (replays all migrations + seed) |
| `supabase migration new <name>` | Generate a new migration file |
| `supabase functions serve <name>` | Run an Edge Function locally with hot reload |
| `./scripts/deploy-function.sh <name>` | Deploy a function to the linked Supabase project |
| `./scripts/test-function-local.sh <name>` | Hit a locally-served function with `curl` |
| `deno task fmt` | Format every file under `supabase/functions/` |
| `deno task lint` | Lint every file under `supabase/functions/` |
| `deno task check` | Type-check every Edge Function entry point |
| `deno task verify` | Run fmt-check + lint + check in one shot |

## Folder structure

```
dangg-backend/
├── docs/                       # CLAUDE.md, API inventory, etc.
├── scripts/                    # Shell helpers for common ops
├── supabase/
│   ├── config.toml             # Local stack configuration
│   ├── seed.sql                # Seed data (placeholder for now)
│   ├── migrations/             # SQL migrations — one per change
│   └── functions/
│       ├── _shared/            # Reusable utilities every function imports
│       └── config-app/         # Reference function (app config endpoint)
├── tests/                      # DB tests + function tests (placeholder)
└── .github/workflows/          # CI (empty for now)
```

## Code style

Formatting and linting are owned by Deno — never argue with the formatter.

- 2-space indent, 100-char line width, single quotes, semicolons required (configured in `deno.json`).
- TypeScript strict; zero `any` (use `unknown` + narrowing).
- Every exported function/class has a `/** */` JSDoc comment explaining purpose.
- Zero `console.log` — use `logger.*` from `_shared/logger.ts`.

Run `deno task verify` before every commit.

## Database conventions

- `snake_case` table and column names.
- All primary keys are `UUID`.
- All timestamps are `TIMESTAMPTZ` — never `TIMESTAMP`.
- Every table has `created_at` and `updated_at`, with a `BEFORE UPDATE` trigger calling `public.set_updated_at()`.
- Every foreign key has explicit `ON DELETE` behavior (`CASCADE` / `SET NULL` / `RESTRICT`).
- Every column used in a `WHERE` or `ORDER BY` of a common query gets an index.
- Soft-delete via `is_active` boolean where appropriate; hard delete only via DPDP cron after the 30-day cooldown.
- Every table has `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` followed by explicit policies. Default deny; explicit grants.
- Every database object (table, view, function, type) has a SQL `COMMENT`.
- All SQL keywords are UPPERCASE.

## Edge Function conventions

Every Edge Function follows this exact pattern:

```typescript
import { handlePreflight } from '../_shared/cors.ts';
import { logger } from '../_shared/logger.ts';
import { handler, ok } from '../_shared/responses.ts';
import { parseBody, z } from '../_shared/validation.ts';
import { requireAuth, requireRole } from '../_shared/auth.ts';

const Body = z.object({ /* ... */ });

Deno.serve(handler(async (req) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  const user = await requireAuth(req);
  requireRole(user, 'female');

  const input = await parseBody(req, Body);

  // ...business logic...

  logger.info('did the thing', { userId: user.id });
  return ok({ /* ... */ });
}));
```

- Always import from `_shared/`; never re-implement CORS / errors / responses / logging.
- Always wrap your handler with `handler(...)`.
- Always validate input via Zod before touching the database or external services.
- Always throw typed `AppError` subclasses — never set HTTP status codes ad-hoc.
- Always use structured `logger.*` — every log call is JSON for Supabase's log UI.

## RLS conventions

- **Default deny.** Every table gets `ENABLE ROW LEVEL SECURITY` at creation time.
- **Explicit grants.** Write a `CREATE POLICY` for every read/write the table should allow.
- **`auth.uid()` for self-scoped access.** Most policies use `auth.uid() = id` or `auth.uid() = user_id`.
- **Service-role bypass is documented.** Anywhere `serviceClient()` is used in an Edge Function, the comment above the call explains why RLS is being skipped.
- **Admin endpoints check role manually.** `requireRole(user, 'admin')` first, then `serviceClient()` for the actual query.

## Webhook idempotency

Every webhook handler (Razorpay, Supabase Auth Hook, etc.) must check an idempotency record before processing. The `webhook_events` table (`UNIQUE(provider, event_id)`) is the enforcement layer — handlers `INSERT` first and treat a `23505` unique-violation as "already processed, return 200." See `supabase/functions/webhooks-razorpay/index.ts` for the canonical pattern.

## Razorpay setup

The payments flow uses **three** secrets, each with a distinct role:

| Var | Where used | What it does |
|---|---|---|
| `RAZORPAY_KEY_ID` | client + server | Public-ish key id. Returned to the mobile app for the Razorpay Checkout SDK. |
| `RAZORPAY_KEY_SECRET` | server only | HMAC-SHA256 key for verifying `payment_id\|order_id` signatures returned to the app after checkout. Also used as HTTP Basic password to call the Razorpay REST API. |
| `RAZORPAY_WEBHOOK_SECRET` | server only | HMAC-SHA256 key for verifying `X-Razorpay-Signature` on incoming webhooks. **Different from `KEY_SECRET`.** Set in Razorpay Dashboard → Webhooks. |

### One-time test-mode setup

1. Sign up at [razorpay.com](https://razorpay.com) — test mode is enabled by default, no KYC needed.
2. Dashboard → **Settings → API Keys → Generate Test Key** → copy `KEY_ID` and `KEY_SECRET` into `.env`.
3. Expose your local Edge Function URL to the internet so Razorpay can deliver webhooks:
   ```bash
   ngrok http 54321
   ```
4. Dashboard → **Settings → Webhooks → Add New Webhook**:
   - URL: `https://<your-ngrok-id>.ngrok.io/functions/v1/webhooks-razorpay`
   - Secret: generate a random string, copy into `RAZORPAY_WEBHOOK_SECRET` in `.env`.
   - Events: subscribe to `payment.captured`, `payment.failed`, `refund.processed`.
5. Restart the stack so Edge Functions pick up the new env: `supabase stop && supabase start`.

### Test cards (test mode only)

| Card | Result |
|---|---|
| `4111 1111 1111 1111` | Success |
| `5104 0600 0000 0008` | Success (Mastercard) |
| `4000 0000 0000 0002` | Declined |

Any future expiry, any 3-digit CVV. UPI test handle: `success@razorpay`.

### End-to-end flow

```
[App] ──► payments-create-order ─┐
                                  ├─► Razorpay REST API ──► returns order_id
[App] ◄──────────────────────────┘
[App] ──► Razorpay Checkout SDK (in-app)
[App] ◄── { razorpay_payment_id, razorpay_signature }
[App] ──► payments-verify ──► verifies signature ──► credit_coins()
                                                          │
[Razorpay] ──► webhooks-razorpay ──► UNIQUE idempotency  │
                                  └─► credit_coins() ◄───┘
                                       (either path wins,
                                        the other is a no-op)
```

The webhook is the **source of truth**. `payments-verify` is a UX optimization that credits coins immediately while the app is foregrounded; if it loses the race against the webhook, the second `UPDATE … WHERE status = 'initiated'` matches zero rows and the function returns the already-credited result.

## Chat request flow

A male sends a chat request to an online verified female. Coins are escrowed (debited immediately) and refunded on every non-accept outcome. A pg_cron job sweeps stale pending rows once a minute.

### State machine

```
              ┌──────────┐ accept   → accepted   (credit female earnings)
   send ───► │ pending  │ decline  → declined   (refund male)
              └──────────┘ cancel   → cancelled  (refund male)
                    │
                    └ expires_at  → expired    (refund male, via pg_cron)
```

All four terminal states are final — no further transitions.

### Coin / earnings movements

| Transition | Male wallet | Female earnings |
|---|---|---|
| send → pending | `-chat_cost_coins` (`chat_charge`) | — |
| pending → accepted | — | `+chat_cost_coins` (`chat_earning`) |
| pending → declined | `+chat_cost_coins` (`chat_refund`) | — |
| pending → cancelled | `+chat_cost_coins` (`chat_refund`) | — |
| pending → expired | `+chat_cost_coins` (`chat_refund`) | — |

The cost is snapshotted at send time. If the female updates her `coin_price` after the request is sent, the request still honours the original price.

### Timeouts & cron

- Pending requests carry `expires_at = sent_at + 120s` (set by `chat-requests-send`).
- `public.expire_pending_chat_requests()` runs every minute via pg_cron, locking candidates with `FOR UPDATE SKIP LOCKED` so it coexists with user-initiated transitions.
- Worst-case latency from miss → "expired" UI: 120s + up to 60s cron = ~3 min.

### Concurrency rules

- **One pending per male.** Enforced by `chat_requests_one_pending_per_male_idx` (partial UNIQUE where `status = 'pending'`). The send Edge Function pre-checks for a friendly 409; the index is the hard guarantee.
- **Optimistic transitions.** Every terminal UPDATE carries `eq.status = 'pending'`. If the row was already transitioned by another path (cron / cancel / decline), the UPDATE matches zero rows and the Edge Function reverses any ledger movement it just made.
- **Locking.** `credit_coins` and `credit_female_earnings` use `FOR UPDATE` on the male / female row, so any two coin movements for the same user serialise rather than race.

### Edge Function inventory

| Endpoint | Auth | Body | Success response |
|---|---|---|---|
| `POST /functions/v1/chat-requests-send` | JWT (male) | `{ femaleId }` | `{ chatRequestId, expiresAt, coinsCharged, newCoinBalance, chargeTransactionId }` |
| `POST /functions/v1/chat-requests-respond` | JWT (female) | `{ chatRequestId, action: 'accept'\|'decline' }` | accept → `{ status:'accepted', earningId, newEarningsBalanceCoins }`<br>decline → `{ status:'declined', refundTransactionId }` |
| `POST /functions/v1/chat-requests-cancel` | JWT (male) | `{ chatRequestId }` | `{ status:'cancelled', refundTransactionId, newCoinBalance }` |

### Mobile integration

**Male — send and watch the result.**

```typescript
const { data } = await supabase.functions.invoke('chat-requests-send', {
  body: { femaleId },
});
// data: { chatRequestId, expiresAt, coinsCharged, newCoinBalance }

const channel = supabase
  .channel(`chat-request-${data.chatRequestId}`)
  .on('postgres_changes', {
    event: 'UPDATE',
    schema: 'public',
    table: 'chat_requests',
    filter: `id=eq.${data.chatRequestId}`,
  }, ({ new: row }) => {
    // row.status is 'accepted' | 'declined' | 'cancelled' | 'expired'
  })
  .subscribe();

// Cancel before she responds
await supabase.functions.invoke('chat-requests-cancel', {
  body: { chatRequestId: data.chatRequestId },
});
```

**Female — listen for incoming, then respond.**

```typescript
const channel = supabase
  .channel('incoming-chat-requests')
  .on('postgres_changes', {
    event: 'INSERT',
    schema: 'public',
    table: 'chat_requests',
    filter: `female_id=eq.${myUserId}`,
  }, ({ new: row }) => {
    showIncomingRequestModal(row);
  })
  .subscribe();

await supabase.functions.invoke('chat-requests-respond', {
  body: { chatRequestId, action: 'accept' }, // or 'decline'
});
```

**Earnings query (female dashboard).**

```typescript
const { data } = await supabase
  .from('female_earnings')
  .select('id, type, amount_coins, balance_after_coins, reference_id, description, created_at')
  .order('created_at', { ascending: false })
  .limit(50);
```

## Common Query Patterns

Most browse + favorites flows are direct PostgREST calls — RLS enforces access, no Edge Function needed. The mobile app does this directly via the Supabase SDK.

### Browse females (paginated, sorted, filtered)
```typescript
const { data, error } = await supabase
  .from('females_available_view')
  .select('*')
  .eq('is_online', true)                  // optional online filter
  .gte('rating_avg', 4)                    // optional rating filter
  .lte('coin_price', 100)                  // optional price filter
  .order('rating_avg', { ascending: false })
  .range(0, 19);                           // pagination: first 20
```

### Get single female profile preview
```typescript
const { data, error } = await supabase
  .from('females_available_view')
  .select('*')
  .eq('female_id', femaleId)
  .single();
```

### List my favorites (with the female's preview data)
```typescript
const { data, error } = await supabase
  .from('favorites')
  .select(`
    female_id,
    created_at,
    female:female_id (
      id,
      name,
      age,
      profile_picture_url
    )
  `)
  .order('created_at', { ascending: false });
```
The nested join targets `users` (since `favorites.female_id` references `public.users(id)`). For a richer preview that includes online status + price, fetch the IDs first then query `females_available_view` with `in_('female_id', ids)`.

### Add a favorite
```typescript
const { error } = await supabase
  .from('favorites')
  .insert({ male_id: user.id, female_id: femaleId });
// RLS rejects unless: auth.uid() = male_id, current_user_role() = 'male',
// and the female is verified / active / non-suspended.
```

### Remove a favorite
```typescript
const { error } = await supabase
  .from('favorites')
  .delete()
  .eq('female_id', femaleId);
// RLS auto-scopes by male_id = auth.uid().
```

### Toggle online (female-only)
```typescript
const { data, error } = await supabase.functions.invoke('female-availability-toggle', {
  body: { isOnline: true },
});
// Returns: { ok: true, data: { isOnline: true, lastOnlineAt: "2026-..." } }
// Error codes: FORBIDDEN (unverified), CONFLICT (no payout_details), INTERNAL_ERROR
```

### Subscribe to online presence changes (males browsing)
```typescript
const channel = supabase
  .channel('female-presence')
  .on('postgres_changes',
    { event: 'UPDATE',
      schema: 'public',
      table: 'females',
      filter: 'verification_status=eq.verified' },
    (payload) => {
      // payload.new contains the updated row — update the card's online dot.
    },
  )
  .subscribe();
```

## Testing

pgTAP tests live under `supabase/tests/database/`. Run with:

```bash
supabase test db
```

Tests run inside a single transaction that rolls back, so no state persists. The first test suite (`01_browse_and_favorites.sql`) proves the privacy invariants of this domain: males can't read payout_details, can't favorite themselves / other males / unverified females; the browse view exposes only the column allowlist; etc.

Deno-test for Edge Functions lives under `tests/functions/` — placeholder for now.

## Deployment

Placeholder. Once the project is linked to Supabase Cloud (`supabase link --project-ref <ref>`), deployment is `./scripts/deploy-function.sh <name>` per function and `supabase db push` for schema. Migration of secrets to Supabase Vault is part of that same prompt.

## Documentation

- [`docs/CLAUDE.md`](./docs/CLAUDE.md) — full project context for AI assistants
- [`docs/DANGG_BACKEND_API_INVENTORY.md`](./docs/DANGG_BACKEND_API_INVENTORY.md) — complete endpoint inventory
- [`docs/API_REFERENCE.md`](./docs/API_REFERENCE.md) — endpoint-level request / response samples
