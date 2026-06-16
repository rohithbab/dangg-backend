/**
 * POST /functions/v1/payouts-cancel
 *
 * Female cancels her own PENDING payout. Once admin has approved
 * (status='approved') the funds are committed to be paid and the female
 * can no longer cancel — that's an admin-only state machine from there.
 *
 * Refunds the escrowed coins via credit_female_earnings('payout_failed_reversal').
 *
 * Auth:    JWT (female)
 * Body:    { payoutId: uuid }
 * Returns: { status:'cancelled', refundedCoins, newEarningsBalanceCoins }
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
import { notify } from '../_shared/notify.ts';
import { formatPaisa } from '../_shared/payout-math.ts';
import { handler, ok } from '../_shared/responses.ts';
import { serviceClient } from '../_shared/supabase-client.ts';
import { parseBody, z } from '../_shared/validation.ts';

const Body = z.object({
  payoutId: z.string().uuid(),
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

    const { payoutId } = await parseBody(req, Body);

    const svc = serviceClient();

    const { data: payout, error: fetchErr } = await svc
      .from('payouts')
      .select('id, female_id, status, coins_requested, payout_amount_paisa')
      .eq('id', payoutId)
      .maybeSingle();

    if (fetchErr) {
      logger.error('payouts-cancel: fetch failed', {
        payoutId,
        error: fetchErr.message,
      });
      throw new InternalError('Could not load payout');
    }
    if (!payout) {
      throw new NotFoundError('Payout not found');
    }
    if (payout.female_id !== user.id) {
      throw new ForbiddenError('This payout does not belong to you');
    }
    if (payout.status !== 'pending') {
      throw new ConflictError(
        `Payout is in '${payout.status}' state and cannot be cancelled. Only pending payouts can be cancelled.`,
      );
    }

    // 1. Refund the escrow.
    const { data: refundRows, error: refundErr } = await svc.rpc(
      'credit_female_earnings',
      {
        p_female_id: user.id,
        p_amount: payout.coins_requested,
        p_type: 'payout_failed_reversal',
        p_reference_id: payout.id,
        p_description: 'Payout cancelled by female',
      },
    );

    if (refundErr || !refundRows || (refundRows as unknown[]).length === 0) {
      logger.error('payouts-cancel: refund failed', {
        payoutId,
        femaleId: user.id,
        error: refundErr?.message,
      });
      throw new InternalError('Failed to cancel payout. Please try again.');
    }

    const refund = (refundRows as Array<{
      earning_id: string;
      previous_balance_coins: number;
      new_balance_coins: number;
    }>)[0];

    // 2. Flip status with optimistic concurrency. If a concurrent admin
    //    transition won the race we reverse the refund.
    const { data: updatedRows, error: updateErr } = await svc
      .from('payouts')
      .update({
        status: 'cancelled',
        cancelled_at: new Date().toISOString(),
        refund_earning_id: refund.earning_id,
      })
      .eq('id', payout.id)
      .eq('status', 'pending')
      .select('id');

    if (updateErr || !updatedRows || updatedRows.length === 0) {
      const { error: reverseErr } = await svc.rpc('credit_female_earnings', {
        p_female_id: user.id,
        p_amount: -payout.coins_requested,
        p_type: 'admin_adjustment',
        p_reference_id: payout.id,
        p_description: 'Reversed: cancel lost race against admin transition',
      });
      if (reverseErr) {
        logger.error('payouts-cancel: refund reversal FAILED — extra earnings on female', {
          payoutId,
          femaleId: user.id,
          refundEarningId: refund.earning_id,
          error: reverseErr.message,
        });
      }
      if (updateErr) {
        logger.error('payouts-cancel: state update failed', {
          payoutId,
          error: updateErr.message,
        });
        throw new InternalError('Failed to finalize cancel');
      }
      throw new ConflictError(
        'Payout transitioned to another state before we could cancel it.',
      );
    }

    // 3. Notify — best-effort.
    await notify(svc, {
      recipientId: user.id,
      type: 'payout_cancelled',
      title: 'Payout cancelled',
      body: `Your payout of ${formatPaisa(payout.payout_amount_paisa)} has been cancelled. ` +
        `${payout.coins_requested} coins returned to your balance.`,
      data: {
        payout_id: payout.id,
        refunded_coins: payout.coins_requested,
        new_balance_coins: refund.new_balance_coins,
      },
    });

    logger.info('Payout cancelled by female', {
      payoutId,
      femaleId: user.id,
      refundedCoins: payout.coins_requested,
    });

    return ok({
      status: 'cancelled',
      refundedCoins: payout.coins_requested,
      newEarningsBalanceCoins: refund.new_balance_coins,
    });
  }),
);
