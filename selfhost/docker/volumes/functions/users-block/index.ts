/**
 * POST /functions/v1/users-block
 *
 * Caller blocks another user. Idempotent — calling twice with the same
 * pair is a no-op (UPSERT on the UNIQUE (blocker_id, blocked_id)).
 *
 * Effects (enforced elsewhere):
 *   * females_available_view excludes the target for the caller (and the
 *     caller for the target) — handled by the view's WHERE NOT EXISTS.
 *   * chat-requests-send rejects in either direction with a generic 403.
 *   * Any already-pending chat-request between them is NOT auto-cancelled
 *     in v1 — admin can intervene manually if needed.
 *
 * Auth:    JWT (any end-user)
 * Body:    { blockedUserId: uuid, reason?: 1..500 chars }
 * Returns: { blockId, blocked:true }
 */
import { requireAuth } from '../_shared/auth.ts';
import { handlePreflight } from '../_shared/cors.ts';
import { InternalError, NotFoundError, ValidationError } from '../_shared/errors.ts';
import { logger } from '../_shared/logger.ts';
import { handler, ok } from '../_shared/responses.ts';
import { serviceClient } from '../_shared/supabase-client.ts';
import { parseBody, z } from '../_shared/validation.ts';

const Body = z.object({
  blockedUserId: z.string().uuid(),
  reason: z.string().trim().min(1).max(500).optional(),
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
    const { blockedUserId, reason } = await parseBody(req, Body);

    if (user.id === blockedUserId) {
      throw new ValidationError('Cannot block yourself');
    }

    const svc = serviceClient();

    const { data: target, error: targetErr } = await svc
      .from('users')
      .select('id')
      .eq('id', blockedUserId)
      .maybeSingle();

    if (targetErr) {
      logger.error('users-block: target lookup failed', {
        blockerId: user.id,
        blockedUserId,
        error: targetErr.message,
      });
      throw new InternalError('Could not look up user');
    }
    if (!target) {
      throw new NotFoundError('User not found');
    }

    // Idempotent upsert on the UNIQUE (blocker_id, blocked_id) pair.
    // ignoreDuplicates=false ensures we get the resulting row id back,
    // whether it was newly inserted or already present.
    const { data: block, error: insertErr } = await svc
      .from('user_blocks')
      .upsert(
        { blocker_id: user.id, blocked_id: blockedUserId, reason: reason ?? null },
        { onConflict: 'blocker_id,blocked_id', ignoreDuplicates: false },
      )
      .select('id')
      .single();

    if (insertErr || !block) {
      logger.error('users-block: insert failed', {
        blockerId: user.id,
        blockedUserId,
        error: insertErr?.message,
      });
      throw new InternalError('Failed to block user. Please try again.');
    }

    logger.info('User blocked', {
      blockerId: user.id,
      blockedId: blockedUserId,
      blockId: block.id,
    });

    return ok({ blockId: block.id, blocked: true });
  }),
);
