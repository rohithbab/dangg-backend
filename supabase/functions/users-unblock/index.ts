/**
 * POST /functions/v1/users-unblock
 *
 * Caller removes a block they authored. Idempotent — DELETE matches
 * zero rows if the block didn't exist, and we return 200 either way.
 *
 * Auth:    JWT (any end-user)
 * Body:    { blockedUserId: uuid }
 * Returns: { unblocked: true }
 */
import { requireAuth } from '../_shared/auth.ts';
import { handlePreflight } from '../_shared/cors.ts';
import { InternalError, ValidationError } from '../_shared/errors.ts';
import { logger } from '../_shared/logger.ts';
import { handler, ok } from '../_shared/responses.ts';
import { serviceClient } from '../_shared/supabase-client.ts';
import { parseBody, z } from '../_shared/validation.ts';

const Body = z.object({
  blockedUserId: z.string().uuid(),
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
    const { blockedUserId } = await parseBody(req, Body);

    const svc = serviceClient();

    const { error: deleteErr } = await svc
      .from('user_blocks')
      .delete()
      .eq('blocker_id', user.id)
      .eq('blocked_id', blockedUserId);

    if (deleteErr) {
      logger.error('users-unblock: delete failed', {
        blockerId: user.id,
        blockedUserId,
        error: deleteErr.message,
      });
      throw new InternalError('Failed to unblock user. Please try again.');
    }

    logger.info('User unblocked', { blockerId: user.id, blockedId: blockedUserId });

    return ok({ unblocked: true });
  }),
);
