/**
 * POST /functions/v1/chat-requests-cancel
 *
 * Male cancels a pending chat request they sent (before the female has
 * responded). Coins are refunded immediately.
 *
 * Auth:    JWT (male)
 * Body:    { chatRequestId: uuid }
 * Returns: { status:'cancelled', refundTransactionId, newCoinBalance }
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
    requireRole(user, 'male');

    const { chatRequestId } = await parseBody(req, Body);

    const svc = serviceClient();

    const { data: cr, error: fetchErr } = await svc
      .from('chat_requests')
      .select('id, male_id, status, chat_cost_coins')
      .eq('id', chatRequestId)
      .maybeSingle();

    if (fetchErr) {
      logger.error('chat-requests-cancel: fetch failed', {
        chatRequestId,
        error: fetchErr.message,
      });
      throw new InternalError('Could not load chat request');
    }
    if (!cr) {
      throw new NotFoundError('Chat request not found');
    }
    if (cr.male_id !== user.id) {
      throw new ForbiddenError('This chat request is not yours to cancel');
    }
    if (cr.status !== 'pending') {
      throw new ConflictError(
        `Chat request is already '${cr.status}' and cannot be cancelled`,
      );
    }

    // 1. Refund first, then flip status. If the flip loses the race,
    //    reverse the refund.
    const { data: refundRows, error: refundErr } = await svc.rpc('credit_coins', {
      p_male_id: user.id,
      p_amount: cr.chat_cost_coins,
      p_type: 'chat_refund',
      p_reference_id: cr.id,
      p_description: 'Refund: chat request cancelled by male',
    });

    if (refundErr || !refundRows || (refundRows as unknown[]).length === 0) {
      logger.error('chat-requests-cancel: refund failed', {
        chatRequestId,
        maleId: user.id,
        error: refundErr?.message,
      });
      throw new InternalError('Failed to cancel. Please try again.');
    }

    const refund = (refundRows as Array<{
      transaction_id: string;
      previous_balance: number;
      new_balance: number;
    }>)[0];

    const { data: updatedRows, error: updateErr } = await svc
      .from('chat_requests')
      .update({
        status: 'cancelled',
        responded_at: new Date().toISOString(),
        response_reason: 'Cancelled by male',
        refund_transaction_id: refund.transaction_id,
      })
      .eq('id', cr.id)
      .eq('status', 'pending')
      .select('id');

    if (updateErr || !updatedRows || updatedRows.length === 0) {
      // Reverse the refund — the male incorrectly got coins back.
      const { error: reverseErr } = await svc.rpc('credit_coins', {
        p_male_id: user.id,
        p_amount: -cr.chat_cost_coins,
        p_type: 'admin_adjustment',
        p_reference_id: cr.id,
        p_description: 'Reversed: cancel lost race against another transition',
      });
      if (reverseErr) {
        logger.error('chat-requests-cancel: refund reversal FAILED — extra coins on male', {
          chatRequestId,
          maleId: user.id,
          refundTxnId: refund.transaction_id,
          error: reverseErr.message,
        });
      }
      if (updateErr) {
        logger.error('chat-requests-cancel: state update failed', {
          chatRequestId,
          error: updateErr.message,
        });
        throw new InternalError('Failed to finalize cancel. Please retry.');
      }
      throw new ConflictError(
        'Chat request transitioned to another state before we could cancel it.',
      );
    }

    logger.info('Chat request cancelled', {
      chatRequestId,
      maleId: user.id,
      refundCoins: cr.chat_cost_coins,
    });

    return ok({
      status: 'cancelled',
      refundTransactionId: refund.transaction_id,
      newCoinBalance: refund.new_balance,
    });
  }),
);
