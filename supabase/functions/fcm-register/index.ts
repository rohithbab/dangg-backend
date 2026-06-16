/**
 * POST /functions/v1/fcm-register
 *
 * Registers (upserts) the caller's FCM device token so the backend can push
 * to them. Upsert is keyed on the token itself — re-registering an existing
 * token just re-points it at the current user (handed-down device) and bumps
 * `last_seen_at`. Uses the service role so a token owned by a previous user
 * can be reassigned (RLS would block that).
 *
 * Auth:    any authenticated user.
 * Body:    { token: string, platform: 'android' | 'ios' | 'web' }
 * Returns: { registered: boolean }
 */
import { requireAuth } from '../_shared/auth.ts';
import { handlePreflight } from '../_shared/cors.ts';
import { ValidationError } from '../_shared/errors.ts';
import { logger } from '../_shared/logger.ts';
import { handler, ok } from '../_shared/responses.ts';
import { serviceClient } from '../_shared/supabase-client.ts';
import { parseBody, z } from '../_shared/validation.ts';

const Body = z.object({
  token: z.string().min(10).max(4096),
  platform: z.enum(['android', 'ios', 'web']),
});

Deno.serve(
  handler(async (req: Request): Promise<Response> => {
    const preflight = handlePreflight(req);
    if (preflight) {
      return preflight;
    }
    if (req.method !== 'POST') {
      throw new ValidationError('Only POST is accepted');
    }

    const user = await requireAuth(req);
    const { token, platform } = await parseBody(req, Body);

    const now = new Date().toISOString();
    const { error } = await serviceClient()
      .from('fcm_tokens')
      .upsert(
        { user_id: user.id, token, platform, updated_at: now, last_seen_at: now },
        { onConflict: 'token' },
      );

    if (error) {
      // Non-fatal: the client retries on next launch / token refresh.
      logger.error('fcm-register: upsert failed', { userId: user.id, error: error.message });
      return ok({ registered: false });
    }

    logger.info('fcm-register: token registered', { userId: user.id, platform });
    return ok({ registered: true });
  }),
);
