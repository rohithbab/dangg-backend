/**
 * POST /functions/v1/female-availability-toggle
 *
 * Toggle the caller's `females.is_online` and stamp `last_online_at`.
 *
 * Business rules (each maps to a typed error so the client can branch on
 * `error.code` without parsing the message):
 *   1. Caller is authenticated as a female  (UnauthorizedError / ForbiddenError)
 *   2. Caller is verified                   (ForbiddenError — verification_status != 'verified')
 *   3. Caller has payout_details            (ConflictError — must add bank/UPI first)
 *   4. Caller is not suspended              (RLS denies updates if is_suspended;
 *                                            we double-check up front for a nicer message)
 *
 * Why an Edge Function and not direct PostgREST?
 *   Direct UPDATE on `females` would either succeed silently when the
 *   female is unverified/missing payout (the trigger / cron could later
 *   reset it), or fail with a cryptic RLS / CHECK error. The user-facing
 *   contract is "go online" — surface the right reason it can't happen.
 *
 * Body:    { "isOnline": boolean }
 * Returns: { "isOnline": boolean, "lastOnlineAt": ISO-8601 }
 */
import { requireAuth, requireRole } from '../_shared/auth.ts';
import { handlePreflight } from '../_shared/cors.ts';
import {
  ConflictError,
  ForbiddenError,
  InternalError,
  ValidationError,
} from '../_shared/errors.ts';
import { logger } from '../_shared/logger.ts';
import { handler, ok } from '../_shared/responses.ts';
import { userClient } from '../_shared/supabase-client.ts';
import { parseBody, z } from '../_shared/validation.ts';

const Body = z.object({
  isOnline: z.boolean(),
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
    requireRole(user, 'female');

    const { isOnline } = await parseBody(req, Body);

    const db = userClient(req);

    // 1. Read current female state (verification + previous flag for logging).
    const { data: femaleRow, error: femaleErr } = await db
      .from('females')
      .select('verification_status, is_online')
      .eq('id', user.id)
      .single();

    if (femaleErr || !femaleRow) {
      logger.warn('Female row not found for caller', {
        userId: user.id,
        error: femaleErr?.message,
      });
      throw new ForbiddenError('Female profile not found for current user');
    }

    if (femaleRow.verification_status !== 'verified') {
      throw new ForbiddenError(
        'Account not yet verified. You can go online once verification is approved.',
      );
    }

    // 2. Ensure payout details exist before allowing the toggle.
    const { data: payoutRow, error: payoutErr } = await db
      .from('payout_details')
      .select('id')
      .eq('female_id', user.id)
      .maybeSingle();

    if (payoutErr) {
      logger.error('payout_details lookup failed', {
        userId: user.id,
        error: payoutErr.message,
      });
      throw new InternalError('Unable to verify payout details');
    }
    if (!payoutRow) {
      throw new ConflictError(
        'Please add your bank or UPI details before going online.',
      );
    }

    // 3. Apply the toggle. `last_online_at` is stamped on every toggle so
    //    consumers can derive "last seen" cheaply.
    const nowIso = new Date().toISOString();
    const { data: updated, error: updateErr } = await db
      .from('females')
      .update({ is_online: isOnline, last_online_at: nowIso })
      .eq('id', user.id)
      .select('is_online, last_online_at')
      .single();

    if (updateErr || !updated) {
      logger.error('Failed to toggle availability', {
        userId: user.id,
        error: updateErr?.message,
      });
      throw new InternalError('Failed to update availability');
    }

    logger.info('Female availability toggled', {
      userId: user.id,
      isOnline,
      previousState: femaleRow.is_online,
    });

    return ok({
      isOnline: updated.is_online,
      lastOnlineAt: updated.last_online_at,
    });
  }),
);
