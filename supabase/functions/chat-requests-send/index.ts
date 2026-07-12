/**
 * POST /functions/v1/chat-requests-send
 *
 * Male sends a chat request to a female. Coins are escrowed (debited
 * immediately) and refunded automatically on decline / cancel / expire.
 *
 * Flow:
 *   1. Auth — caller must be male.
 *   2. Validate input — femaleId is a UUID, not self.
 *   3. Load target — must be a verified, active, online, non-suspended female.
 *   4. Confirm male has no existing pending request (friendly error;
 *      the partial-unique index is the hard guard).
 *   5. INSERT chat_requests row first — wins the race for the unique
 *      slot before we touch the coin balance.
 *   6. Debit coins via credit_coins('chat_charge'). On failure delete
 *      the row so the male's slot frees up.
 *   7. Patch chat_requests.charge_transaction_id with the ledger id.
 *
 * Auth:    JWT (male)
 * Body:    { femaleId: uuid }
 * Returns: { chatRequestId, expiresAt, coinsCharged, newCoinBalance,
 *            chargeTransactionId }
 */
import { requireAuth, requireRole } from '../_shared/auth.ts';
import { handlePreflight } from '../_shared/cors.ts';
import {
  ConflictError,
  ForbiddenError,
  InternalError,
  NotFoundError,
  PaymentRequiredError,
  ValidationError,
} from '../_shared/errors.ts';
import { logger } from '../_shared/logger.ts';
import { getUserDisplayName, notify } from '../_shared/notify.ts';
import { handler, ok } from '../_shared/responses.ts';
import { serviceClient } from '../_shared/supabase-client.ts';
import { parseBody, z } from '../_shared/validation.ts';

const TIMEOUT_SECONDS = 120;

const Body = z.object({
  femaleId: z.string().uuid(),
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

    // 1. Auth.
    const user = await requireAuth(req);
    requireRole(user, 'male');

    // 2. Input.
    const { femaleId } = await parseBody(req, Body);
    if (femaleId === user.id) {
      throw new ValidationError('Cannot send a chat request to yourself');
    }

    const svc = serviceClient();

    // 3. Load the target. Service client so the female's coin_price is
    //    readable even though males don't have a direct RLS path to
    //    `females` rows for non-browseable females.
    const { data: target, error: targetErr } = await svc
      .from('users')
      .select(`
        id,
        role,
        is_active,
        is_suspended,
        females!inner (
          verification_status,
          is_online,
          coin_price
        )
      `)
      .eq('id', femaleId)
      .maybeSingle();

    if (targetErr) {
      logger.error('chat-requests-send: failed to load target', {
        femaleId,
        error: targetErr.message,
      });
      throw new InternalError('Could not look up target user');
    }
    if (!target) {
      throw new NotFoundError('Female user not found');
    }
    if (target.role !== 'female') {
      throw new ValidationError('Target user is not a female');
    }
    if (!target.is_active || target.is_suspended) {
      throw new ForbiddenError('Female user is not available');
    }

    // The !inner join guarantees `females` row exists; the JS client returns
    // an object (not array) for !inner joins on a 1:1 relationship.
    const femaleRow = target.females as unknown as {
      verification_status: string;
      is_online: boolean;
      coin_price: number;
    };

    if (femaleRow.verification_status !== 'verified') {
      throw new ForbiddenError('Female user is not verified');
    }
    if (!femaleRow.is_online) {
      throw new ConflictError('Female user is offline. Try someone who is online.');
    }

    // 3c. Busy check — a female may hold only ONE active chat at a time. If she
    //     is already in a live session she cannot receive new requests. Derived
    //     from chat_sessions, so it clears automatically when that chat ends.
    //     Checked BEFORE any coin charge so a busy target never costs the male.
    const { data: activeSession, error: activeErr } = await svc
      .from('chat_sessions')
      .select('id')
      .eq('female_id', femaleId)
      .eq('status', 'active')
      .limit(1)
      .maybeSingle();
    if (activeErr) {
      logger.error('chat-requests-send: active-session lookup failed', {
        femaleId,
        error: activeErr.message,
      });
      throw new InternalError('Could not check availability');
    }
    if (activeSession) {
      throw new ConflictError('She is busy in another chat right now. Please try again in a little while.');
    }

    const chatCost = femaleRow.coin_price;
    if (!Number.isInteger(chatCost) || chatCost <= 0) {
      logger.error('chat-requests-send: invalid coin_price', { femaleId, chatCost });
      throw new InternalError('Invalid chat cost configuration');
    }

    // 3b. Bidirectional block check. Both directions in one query so the
    //     error stays deliberately generic — never leak which side
    //     authored the block (preserves user_blocks' unidirectional
    //     disclosure invariant).
    const { data: blockRow, error: blockErr } = await svc
      .from('user_blocks')
      .select('id')
      .or(
        `and(blocker_id.eq.${user.id},blocked_id.eq.${femaleId}),` +
          `and(blocker_id.eq.${femaleId},blocked_id.eq.${user.id})`,
      )
      .limit(1)
      .maybeSingle();

    if (blockErr) {
      logger.error('chat-requests-send: block lookup failed', {
        maleId: user.id,
        femaleId,
        error: blockErr.message,
      });
      throw new InternalError('Could not verify block status');
    }
    if (blockRow) {
      throw new ForbiddenError('Cannot send chat request to this user.');
    }

    // 4. Friendly pre-check — the partial unique index is the hard guard,
    //    but this lets us return a meaningful 409 instead of a Postgres
    //    constraint message.
    const { data: existingPending, error: pendingErr } = await svc
      .from('chat_requests')
      .select('id, expires_at')
      .eq('male_id', user.id)
      .eq('status', 'pending')
      .maybeSingle();

    if (pendingErr) {
      logger.error('chat-requests-send: pending lookup failed', {
        maleId: user.id,
        error: pendingErr.message,
      });
      throw new InternalError('Could not check pending requests');
    }
    if (existingPending) {
      throw new ConflictError(
        'You already have a pending chat request. Wait for it to resolve before sending another.',
      );
    }

    // 5. Coin-balance pre-check. credit_coins() is the authoritative gate
    //    (overdraft → check_violation), but a friendly 402 beats a generic
    //    500 when the caller is just broke.
    const { data: maleRow, error: maleErr } = await svc
      .from('males')
      .select('coin_balance')
      .eq('id', user.id)
      .maybeSingle();

    if (maleErr || !maleRow) {
      logger.error('chat-requests-send: male row lookup failed', {
        maleId: user.id,
        error: maleErr?.message,
      });
      throw new InternalError('Could not load wallet');
    }
    if (maleRow.coin_balance < chatCost) {
      // DEV ONLY: mock a wallet top-up so the request flow (and the female's
      // incoming slideable card) can be exercised without a real Razorpay
      // purchase. Strictly gated on APP_ENV=development — never grants free
      // coins in staging/production, where the PaymentRequired below stands.
      const isDev = (Deno.env.get('APP_ENV') ?? '').toLowerCase() === 'development';
      if (isDev) {
        const grant = Math.max(chatCost, 1000);
        const { error: grantErr } = await svc.rpc('credit_coins', {
          p_male_id: user.id,
          p_amount: grant,
          p_type: 'admin_adjustment',
          p_reference_id: null,
          p_description: 'DEV mock coin grant (insufficient balance on send)',
        });
        if (grantErr) {
          logger.error('chat-requests-send: dev coin grant failed', {
            maleId: user.id,
            error: grantErr.message,
          });
          throw new PaymentRequiredError(
            `Insufficient coins. You have ${maleRow.coin_balance}; need ${chatCost}.`,
          );
        }
        logger.info('chat-requests-send: DEV granted mock coins', {
          maleId: user.id,
          grant,
          previousBalance: maleRow.coin_balance,
        });
      } else {
        throw new PaymentRequiredError(
          `Insufficient coins. You have ${maleRow.coin_balance}; need ${chatCost}.`,
        );
      }
    }

    // 6. INSERT chat_request first — this reserves the male's
    //    "one pending" slot via the partial unique index before we touch
    //    coins. If a concurrent send races to here, exactly one wins.
    const sentAt = new Date();
    const expiresAt = new Date(sentAt.getTime() + TIMEOUT_SECONDS * 1000);

    const { data: inserted, error: insertErr } = await svc
      .from('chat_requests')
      .insert({
        male_id: user.id,
        female_id: femaleId,
        chat_cost_coins: chatCost,
        status: 'pending',
        sent_at: sentAt.toISOString(),
        expires_at: expiresAt.toISOString(),
      })
      .select('id')
      .single();

    if (insertErr || !inserted) {
      // 23505 = unique violation on chat_requests_one_pending_per_male_idx.
      if ((insertErr as { code?: string } | null)?.code === '23505') {
        throw new ConflictError('You already have a pending chat request.');
      }
      logger.error('chat-requests-send: insert failed', {
        maleId: user.id,
        femaleId,
        error: insertErr?.message,
      });
      throw new InternalError('Failed to send chat request. Please try again.');
    }

    const chatRequestId = inserted.id as string;

    // Duration-only billing: NO upfront escrow / charge on send. The male is
    // charged at chat END by actual duration (ceil(seconds / 3) coins) in
    // chat-sessions-end, and there is NO refund. The balance pre-check above
    // (needs >= the female's coin_price) is the "minimum balance to start".

    // 7. Notify the female (best-effort — notify() never throws).
    const senderName = await getUserDisplayName(svc, user.id);
    await notify(svc, {
      recipientId: femaleId,
      type: 'chat_request_received',
      title: 'New chat request',
      body: `${senderName} wants to chat with you`,
      data: {
        chat_request_id: chatRequestId,
        from_user_id: user.id,
        from_user_name: senderName,
        chat_cost_coins: chatCost,
        expires_at: expiresAt.toISOString(),
      },
    });

    logger.info('Chat request sent', {
      chatRequestId,
      maleId: user.id,
      femaleId,
      chatCost,
      expiresAt: expiresAt.toISOString(),
    });

    return ok({
      chatRequestId,
      expiresAt: expiresAt.toISOString(),
      coinsCharged: 0,
      newCoinBalance: maleRow.coin_balance,
      chargeTransactionId: null,
    });
  }),
);
