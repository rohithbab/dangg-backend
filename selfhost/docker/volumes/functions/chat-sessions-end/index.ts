/**
 * POST /functions/v1/chat-sessions-end
 *
 * Either participant ends a live chat session. Settles the female's earning
 * against the male's escrowed chat_cost_coins by ACTUAL duration:
 *
 *   actualCoins = min(floor(duration_seconds / 3), chat_cost_coins)
 *   unusedCoins = chat_cost_coins - actualCoins
 *
 * chat-requests-respond already credited the female (and debited the male)
 * the FULL chat_cost_coins at accept time as an upfront escrow — this only
 * settles the DIFFERENCE: refunds the male's unused escrow and reverses the
 * female's excess credit. A short chat nets both sides a fair, duration-based
 * amount instead of the flat upfront fee.
 *
 * Idempotent: ending an already-ended session returns its settled values
 * instead of erroring — the app calls this from both screen-unmount and
 * app-background handlers, so a double call is expected, not an error.
 *
 * Auth:    JWT (male or female — must be a participant)
 * Body:    { chatSessionId: uuid }
 * Returns: { status:'ended', durationSeconds, coinsSettled, coinsRefunded }
 */
import { requireAuth, requireRole } from '../_shared/auth.ts';
import { handlePreflight } from '../_shared/cors.ts';
import {
  ForbiddenError,
  InternalError,
  NotFoundError,
  ValidationError,
} from '../_shared/errors.ts';
import { logger } from '../_shared/logger.ts';
import { handler, ok } from '../_shared/responses.ts';
import { serviceClient } from '../_shared/supabase-client.ts';
import { parseBody, z } from '../_shared/validation.ts';

const Body = z.object({
  chatSessionId: z.string().uuid(),
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
    requireRole(user, 'male', 'female');

    const { chatSessionId } = await parseBody(req, Body);

    const svc = serviceClient();

    // 1. Load the session + its request's escrow cap.
    const { data: session, error: fetchErr } = await svc
      .from('chat_sessions')
      .select(
        'id, status, male_id, female_id, chat_request_id, duration_seconds, coins_settled, ' +
          'chat_requests!inner(chat_cost_coins)',
      )
      .eq('id', chatSessionId)
      .maybeSingle();

    if (fetchErr) {
      logger.error('chat-sessions-end: fetch failed', {
        chatSessionId,
        error: fetchErr.message,
      });
      throw new InternalError('Could not load chat session');
    }
    if (!session) {
      throw new NotFoundError('Chat session not found');
    }
    if (session.male_id !== user.id && session.female_id !== user.id) {
      throw new ForbiddenError('This chat session is not yours');
    }

    // Already settled — a race between the unmount and app-background
    // handlers, or a client retry. Return the prior result, not an error.
    if (session.status !== 'active') {
      return ok({
        status: 'ended',
        durationSeconds: session.duration_seconds ?? 0,
        coinsCharged: session.coins_settled ?? 0,
      });
    }

    // 2. Atomically claim the end — the status guard means only one
    //    concurrent caller proceeds to settle money.
    const { data: updated, error: updateErr } = await svc
      .from('chat_sessions')
      .update({ status: 'ended', ended_at: new Date().toISOString(), ended_by: user.id })
      .eq('id', chatSessionId)
      .eq('status', 'active')
      .select('started_at, ended_at')
      .maybeSingle();

    if (updateErr) {
      logger.error('chat-sessions-end: status flip failed', {
        chatSessionId,
        error: updateErr.message,
      });
      throw new InternalError('Failed to end chat session');
    }
    if (!updated) {
      // Lost the race — re-read whatever the winner settled.
      const { data: settled } = await svc
        .from('chat_sessions')
        .select('duration_seconds, coins_settled')
        .eq('id', chatSessionId)
        .maybeSingle();
      return ok({
        status: 'ended',
        durationSeconds: settled?.duration_seconds ?? 0,
        coinsCharged: settled?.coins_settled ?? 0,
      });
    }

    const startedMs = new Date(updated.started_at).getTime();
    const endedMs = new Date(updated.ended_at).getTime();
    const durationSeconds = Math.max(0, Math.floor((endedMs - startedMs) / 1000));

    // Duration-only billing (no escrow, no refund):
    //   male charged = ceil(seconds / 3) coins (3s = 1 coin), CAPPED at his
    //                  current balance so he can never go negative.
    //   female earns = seconds coins (1 coin/sec); each earning-coin nets
    //                  ₹0.04, so her earning = seconds × ₹0.04.
    const grossChargeCoins = Math.ceil(durationSeconds / 3);
    const { data: maleWallet } = await svc
      .from('males')
      .select('coin_balance')
      .eq('id', session.male_id)
      .maybeSingle();
    const maleBalance = Math.max(0, maleWallet?.coin_balance ?? 0);
    const chargeCoins = Math.min(grossChargeCoins, maleBalance);
    const earnCoins = durationSeconds;

    // Stamp the settled values (display/audit; the ledger writes below are the
    // source of truth for balances).
    const { error: stampErr } = await svc
      .from('chat_sessions')
      .update({ duration_seconds: durationSeconds, coins_settled: chargeCoins })
      .eq('id', chatSessionId);
    if (stampErr) {
      logger.warn('chat-sessions-end: failed to stamp settlement values', {
        chatSessionId,
        error: stampErr.message,
      });
    }

    // Charge the male by actual duration (capped; never negative).
    if (chargeCoins > 0) {
      const { error: chargeErr } = await svc.rpc('credit_coins', {
        p_male_id: session.male_id,
        p_amount: -chargeCoins,
        p_type: 'chat_charge',
        p_reference_id: session.chat_request_id,
        p_description: `Chat ${durationSeconds}s — ${chargeCoins} coins`,
      });
      if (chargeErr) {
        logger.error('chat-sessions-end: male charge FAILED — needs reconciliation', {
          chatSessionId,
          maleId: session.male_id,
          chargeCoins,
          error: chargeErr.message,
        });
      }
    }

    // Credit the female by duration (1 coin/sec, each nets ₹0.04).
    if (earnCoins > 0) {
      const { error: earnErr } = await svc.rpc('credit_female_earnings', {
        p_female_id: session.female_id,
        p_amount: earnCoins,
        p_type: 'chat_earning',
        p_reference_id: session.chat_request_id,
        p_description: `Chat ${durationSeconds}s`,
      });
      if (earnErr) {
        logger.error('chat-sessions-end: female earning FAILED — needs reconciliation', {
          chatSessionId,
          femaleId: session.female_id,
          earnCoins,
          error: earnErr.message,
        });
      }
    }

    logger.info('Chat session settled (duration billing)', {
      chatSessionId,
      durationSeconds,
      chargeCoins,
      earnCoins,
    });

    return ok({
      status: 'ended',
      durationSeconds,
      coinsCharged: chargeCoins,
      earningsCoins: earnCoins,
    });
  }),
);
