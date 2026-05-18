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

Every webhook handler (Razorpay, Supabase Auth Hook, etc.) must check an idempotency record before processing. The `webhook_events` table for this will land in a later migration; the pattern is enforced at PR review.

## Testing

Placeholder. Once the auth flow ships, we'll wire pgTAP tests in `tests/database/` and Deno-test in `tests/functions/`.

## Deployment

Placeholder. Once the project is linked to Supabase Cloud (`supabase link --project-ref <ref>`), deployment is `./scripts/deploy-function.sh <name>` per function and `supabase db push` for schema. Migration of secrets to Supabase Vault is part of that same prompt.

## Documentation

- [`docs/CLAUDE.md`](./docs/CLAUDE.md) — full project context for AI assistants
- [`docs/DANGG_BACKEND_API_INVENTORY.md`](./docs/DANGG_BACKEND_API_INVENTORY.md) — complete endpoint inventory
- [`docs/API_REFERENCE.md`](./docs/API_REFERENCE.md) — endpoint-level request / response samples
