/**
 * Supabase client factories for Edge Functions.
 *
 * Two flavours — use the right one for the call site:
 *
 *   userClient(req)   — JWT-scoped, RLS-enforced. Use for ALL user-facing
 *                       endpoints. Reads `Authorization` from the request
 *                       and forwards it to Supabase, so RLS sees the right
 *                       `auth.uid()`.
 *   serviceClient()   — Service-role key. BYPASSES RLS. Use ONLY for admin
 *                       operations, webhooks (Razorpay, Supabase), and
 *                       scheduled cron jobs.
 *
 * NEVER use `serviceClient()` for a user-initiated request unless you've
 * already verified the caller's identity and explicitly need to bypass RLS
 * (e.g., an admin endpoint that performs cross-user lookups). Default to
 * `userClient(req)` and let RLS do its job.
 */
import { createClient, type SupabaseClient } from '@supabase/supabase-js';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

/**
 * Returns a Supabase client scoped to the calling user's JWT. RLS policies
 * are enforced; the client can only see / modify rows the user is allowed to.
 */
export function userClient(req: Request): SupabaseClient {
  const authHeader = req.headers.get('Authorization') ?? '';
  return createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/**
 * Returns a service-role Supabase client. Bypasses RLS entirely. Use with
 * extreme care — wrap in explicit caller-authorisation checks first.
 */
export function serviceClient(): SupabaseClient {
  return createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}
