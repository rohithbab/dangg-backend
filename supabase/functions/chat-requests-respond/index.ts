/**
 * POST /functions/v1/chat-requests-respond
 *
 * Female accepts or declines a pending chat request she received.
 *
 *   accept  → status='accepted'.  Earnings credited to the female.
 *             Male's escrowed coins stay deducted (this IS the spend).
 *   decline → status='declined'.  Male's coins refunded.
 *
 * Concurrency:
 *   The terminal UPDATE carries an `eq.status, 'pending'` guard so a
 *   concurrent expire / cancel cannot collide with us. If 0 rows match
 *   we know the request transitioned out from under us and the ledger
 *   movement we just made is reversed.
 *
 * Auth:    JWT (female)
 * Body:    { chatRequestId: uuid, action: 'accept' | 'decline' }
 * Returns: accept  → { status:'accepted', earningId, newEarningsBalanceCoins }
 *          decline → { status:'declined', refundTransactionId }
 */
import { requireAuth, requireRole } from '../_shared/auth.ts';
import { handlePreflight } from '../_shared/cors.ts';
import {
  ConflictError,
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
  chatRequestId: z.string().uuid(),
  action: z.enum(['accept', 'decline']),
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
    requireRole(user, 'female');

    // 2. Input.
    const { chatRequestId, action } = await parseBody(req, Body);

    const svc = serviceClient();

    // 3. Load + ownership + state + expiry checks.
    const { data: cr, error: fetchErr } = await svc
      .from('chat_requests')
      .select(
        'id, male_id, female_id, status, chat_cost_coins, expires_at',
      )
      .eq('id', chatRequestId)
      .maybeSingle();

    if (fetchErr) {
      logger.error('chat-requests-respond: fetch failed', {
        chatRequestId,
        error: fetchErr.message,
      });
      throw new InternalError('Could not load chat request');
    }
    if (!cr) {
      throw new NotFoundError('Chat request not found');
    }
    if (cr.female_id !== user.id) {
      throw new ForbiddenError('This chat request is not addressed to you');
    }
    if (cr.status !== 'pending') {
      throw new ConflictError(
        `Chat request is already '${cr.status}' and cannot be changed`,
      );
    }
    if (new Date(cr.expires_at).getTime() <= Date.now()) {
      // The expiry cron will pick this up on the next minute; refusing here
      // prevents a race where we credit female earnings on an already-stale
      // request that the cron is about to refund.
      throw new ConflictError('This chat request has expired');
    }

    const respondedAt = new Date().toISOString();

    if (action === 'accept') {
      // 4a. Credit female earnings BEFORE the status flip — if the flip
      //     fails (optimistic-concurrency miss), we reverse the credit.
      const { data: earningRows, error: earningErr } = await svc.rpc(
        'credit_female_earnings',
        {
          p_female_id: user.id,
          p_amount: cr.chat_cost_coins,
          p_type: 'chat_earning',
          p_reference_id: cr.id,
          p_description: 'Accepted chat request',
        },
      );

      if (earningErr || !earningRows || (earningRows as unknown[]).length === 0) {
        logger.error('chat-requests-respond: earnings credit failed', {
          chatRequestId,
          femaleId: user.id,
          error: earningErr?.message,
        });
        throw new InternalError('Failed to accept chat request. Please try again.');
      }

      const earning = (earningRows as Array<{
        earning_id: string;
        previous_balance_coins: number;
        new_balance_coins: number;
      }>)[0];

      // 4b. Atomic state flip — eq.status='pending' guards against concurrent
      //     decline / cancel / expire. .select() returns the updated row, or
      //     empty if no row matched.
      const { data: updatedRows, error: updateErr } = await svc
        .from('chat_requests')
        .update({
          status: 'accepted',
          responded_at: respondedAt,
          response_reason: 'Accepted by female',
          earning_id: earning.earning_id,
        })
        .eq('id', cr.id)
        .eq('status', 'pending')
        .select('id');

      if (updateErr || !updatedRows || updatedRows.length === 0) {
        // Reverse the earnings credit — the row transitioned without us.
        const { error: reverseErr } = await svc.rpc('credit_female_earnings', {
          p_female_id: user.id,
          p_amount: -cr.chat_cost_coins,
          p_type: 'chat_earning_reversed',
          p_reference_id: cr.id,
          p_description: 'Reversed: status update lost race against another transition',
        });
        if (reverseErr) {
          logger.error('chat-requests-respond: reversal FAILED — orphaned earnings', {
            chatRequestId,
            femaleId: user.id,
            earningId: earning.earning_id,
            error: reverseErr.message,
          });
        }
        if (updateErr) {
          logger.error('chat-requests-respond: accept update failed', {
            chatRequestId,
            error: updateErr.message,
          });
          throw new InternalError('Failed to finalize acceptance. Please retry.');
        }
        throw new ConflictError(
          'Chat request transitioned to another state before we could accept it.',
        );
      }

      logger.info('Chat request accepted', {
        chatRequestId,
        femaleId: user.id,
        maleId: cr.male_id,
        earningCoins: cr.chat_cost_coins,
      });

      return ok({
        status: 'accepted',
        earningId: earning.earning_id,
        newEarningsBalanceCoins: earning.new_balance_coins,
      });
    }

    // action === 'decline' — refund the male.
    const { data: refundRows, error: refundErr } = await svc.rpc('credit_coins', {
      p_male_id: cr.male_id,
      p_amount: cr.chat_cost_coins,
      p_type: 'chat_refund',
      p_reference_id: cr.id,
      p_description: 'Refund: chat request declined',
    });

    if (refundErr || !refundRows || (refundRows as unknown[]).length === 0) {
      logger.error('chat-requests-respond: refund failed', {
        chatRequestId,
        maleId: cr.male_id,
        error: refundErr?.message,
      });
      throw new InternalError('Failed to decline cleanly. Please try again.');
    }

    const refund = (refundRows as Array<{
      transaction_id: string;
      previous_balance: number;
      new_balance: number;
    }>)[0];

    const { data: updatedRows, error: updateErr } = await svc
      .from('chat_requests')
      .update({
        status: 'declined',
        responded_at: respondedAt,
        response_reason: 'Declined by female',
        refund_transaction_id: refund.transaction_id,
      })
      .eq('id', cr.id)
      .eq('status', 'pending')
      .select('id');

    if (updateErr || !updatedRows || updatedRows.length === 0) {
      // Reverse the refund — the male incorrectly got coins back.
      const { error: reverseErr } = await svc.rpc('credit_coins', {
        p_male_id: cr.male_id,
        p_amount: -cr.chat_cost_coins,
        p_type: 'admin_adjustment',
        p_reference_id: cr.id,
        p_description: 'Reversed: decline lost race against another transition',
      });
      if (reverseErr) {
        logger.error('chat-requests-respond: refund reversal FAILED — extra coins on male', {
          chatRequestId,
          maleId: cr.male_id,
          refundTxnId: refund.transaction_id,
          error: reverseErr.message,
        });
      }
      if (updateErr) {
        logger.error('chat-requests-respond: decline update failed', {
          chatRequestId,
          error: updateErr.message,
        });
        throw new InternalError('Failed to finalize decline. Please retry.');
      }
      throw new ConflictError(
        'Chat request transitioned to another state before we could decline it.',
      );
    }

    logger.info('Chat request declined', {
      chatRequestId,
      femaleId: user.id,
      maleId: cr.male_id,
      refundCoins: cr.chat_cost_coins,
    });

    return ok({
      status: 'declined',
      refundTransactionId: refund.transaction_id,
    });
  }),
);
