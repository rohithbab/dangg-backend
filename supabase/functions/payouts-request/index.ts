/**
 * POST /functions/v1/payouts-request
 *
 * Female initiates a withdrawal. Steps:
 *   1. Auth — female only.
 *   2. Validate net payout amount ≥ MIN_PAYOUT_PAISA (₹100).
 *   3. Confirm she has payout_details set.
 *   4. Friendly pre-check: no in-flight payout (partial unique index is the
 *      hard guarantee — concurrent racers get 409 from 23505).
 *   5. Confirm earnings_balance_coins ≥ amount.
 *   6. Snapshot the current rates + payout_method into JSONB.
 *   7. Escrow the coins via credit_female_earnings('payout').
 *   8. INSERT the payouts row. On insert failure, refund the escrow.
 *   9. Backfill the escrow ledger's reference_id with the new payout.id.
 *  10. Notify the female (best-effort).
 *
 * Auth:    JWT (female)
 * Body:    { coinsToWithdraw: int > 0 } — rejected if net rupee value < MIN_PAYOUT_PAISA
 * Returns: { payoutId, coinsRequested, payoutAmountPaisa, payoutAmountFormatted,
 *            expectedDays, escrowEarningId, requestedAt }
 */
import { requireAuth, requireRole } from '../_shared/auth.ts';
import { handlePreflight } from '../_shared/cors.ts';
import {
  ConflictError,
  InternalError,
  PaymentRequiredError,
  ValidationError,
} from '../_shared/errors.ts';
import { logger } from '../_shared/logger.ts';
import { notify } from '../_shared/notify.ts';
import { calculatePayoutPaisa, formatPaisa, getPayoutRates } from '../_shared/payout-math.ts';
import { handler, ok } from '../_shared/responses.ts';
import { serviceClient } from '../_shared/supabase-client.ts';
import { parseBody, z } from '../_shared/validation.ts';

const Body = z.object({
  coinsToWithdraw: z.number().int().positive(),
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

    // 2. Input + minimum rupee floor.
    const { coinsToWithdraw } = await parseBody(req, Body);
    const rates = getPayoutRates();
    const previewPaisa = calculatePayoutPaisa(coinsToWithdraw, rates.coinValuePaisa, rates.commissionPct);
    if (previewPaisa < rates.minPayoutPaisa) {
      throw new ValidationError(
        `Minimum payout is ${formatPaisa(rates.minPayoutPaisa)}. Your ${coinsToWithdraw} coins are worth ${formatPaisa(previewPaisa)}.`,
      );
    }

    const svc = serviceClient();

    // 3. payout_details must exist (no FK constraint between payouts and
    //    payout_details — we keep the relationship soft so females can edit
    //    or delete their details without cascade chaos).
    const { data: pd, error: pdErr } = await svc
      .from('payout_details')
      .select('method, account_holder_name, account_number, ifsc_code, upi_id')
      .eq('female_id', user.id)
      .maybeSingle();

    if (pdErr) {
      logger.error('payouts-request: payout_details lookup failed', {
        femaleId: user.id,
        error: pdErr.message,
      });
      throw new InternalError('Failed to verify payout details');
    }
    if (!pd) {
      throw new ConflictError(
        'Please add your bank or UPI details before requesting a payout',
      );
    }

    // 4. Friendly pre-check for an in-flight payout. The partial unique
    //    index is the hard guarantee; this gives a clean 409.
    const { data: active, error: activeErr } = await svc
      .from('payouts')
      .select('id, status')
      .eq('female_id', user.id)
      .in('status', ['pending', 'approved'])
      .maybeSingle();

    if (activeErr) {
      logger.error('payouts-request: active payout lookup failed', {
        femaleId: user.id,
        error: activeErr.message,
      });
      throw new InternalError('Failed to check in-flight payouts');
    }
    if (active) {
      throw new ConflictError(
        `You already have a payout in progress (status: ${active.status}). Wait for it to finish before requesting another.`,
      );
    }

    // 5. Earnings balance check (advisory; credit_female_earnings enforces
    //    the hard rule under FOR UPDATE).
    const { data: female, error: femaleErr } = await svc
      .from('females')
      .select('earnings_balance_coins')
      .eq('id', user.id)
      .maybeSingle();

    if (femaleErr || !female) {
      logger.error('payouts-request: female row lookup failed', {
        femaleId: user.id,
        error: femaleErr?.message,
      });
      throw new InternalError('Could not load earnings');
    }
    if (female.earnings_balance_coins < coinsToWithdraw) {
      throw new PaymentRequiredError(
        `Insufficient earnings. You have ${female.earnings_balance_coins} coins; requested ${coinsToWithdraw}.`,
      );
    }

    // 6. Snapshot the rates + payout method.
    const payoutAmountPaisa = previewPaisa;
    if (payoutAmountPaisa <= 0) {
      // Should be unreachable given the min-coins floor and rate sanity
      // checks in parsePercent, but the CHECK constraint requires > 0.
      logger.error('payouts-request: computed non-positive amount', {
        femaleId: user.id,
        coinsToWithdraw,
        rates,
      });
      throw new InternalError('Computed payout amount is not positive');
    }

    const methodSnapshot = pd.method === 'bank'
      ? {
        method: 'bank',
        account_holder_name: pd.account_holder_name,
        account_number: pd.account_number,
        ifsc_code: pd.ifsc_code,
      }
      : {
        method: 'upi',
        upi_id: pd.upi_id,
      };

    // 7. Escrow the coins. Reference_id is backfilled after we know the
    //    new payout.id (next step).
    const { data: escrowRows, error: escrowErr } = await svc.rpc(
      'credit_female_earnings',
      {
        p_female_id: user.id,
        p_amount: -coinsToWithdraw,
        p_type: 'payout',
        p_reference_id: null,
        p_description: `Payout request escrow (${coinsToWithdraw} coins)`,
      },
    );

    if (escrowErr || !escrowRows || (escrowRows as unknown[]).length === 0) {
      const msg = escrowErr?.message ?? '';
      if (msg.includes('Insufficient earnings balance')) {
        throw new PaymentRequiredError('Insufficient earnings balance');
      }
      logger.error('payouts-request: escrow failed', {
        femaleId: user.id,
        coinsToWithdraw,
        error: msg,
      });
      throw new InternalError('Failed to escrow earnings. Please try again.');
    }

    const escrow = (escrowRows as Array<{
      earning_id: string;
      previous_balance_coins: number;
      new_balance_coins: number;
    }>)[0];

    // 8. INSERT the payout row. On failure, refund the escrow.
    const { data: payout, error: insertErr } = await svc
      .from('payouts')
      .insert({
        female_id: user.id,
        coins_requested: coinsToWithdraw,
        coin_value_paisa_snapshot: rates.coinValuePaisa,
        commission_pct_snapshot: rates.commissionPct,
        payout_amount_paisa: payoutAmountPaisa,
        payout_method_snapshot: methodSnapshot,
        status: 'pending',
        escrow_earning_id: escrow.earning_id,
      })
      .select('id, requested_at')
      .single();

    if (insertErr || !payout) {
      // Reverse the escrow — we never created the payout the coins were for.
      const { error: reverseErr } = await svc.rpc('credit_female_earnings', {
        p_female_id: user.id,
        p_amount: coinsToWithdraw,
        p_type: 'payout_failed_reversal',
        p_reference_id: null,
        p_description: 'Rollback: payouts insert failed',
      });
      if (reverseErr) {
        logger.error('payouts-request: escrow REVERSAL FAILED — orphan debit', {
          femaleId: user.id,
          escrowEarningId: escrow.earning_id,
          error: reverseErr.message,
        });
      }

      // 23505 = unique violation on payouts_one_active_per_female_idx.
      if ((insertErr as { code?: string } | null)?.code === '23505') {
        throw new ConflictError('You already have a payout in progress');
      }
      logger.error('payouts-request: insert failed', {
        femaleId: user.id,
        error: insertErr?.message,
      });
      throw new InternalError('Failed to create payout request');
    }

    // 9. Backfill the escrow ledger row with the payout id for audit.
    const { error: backfillErr } = await svc
      .from('female_earnings')
      .update({ reference_id: payout.id })
      .eq('id', escrow.earning_id);

    if (backfillErr) {
      // Cosmetic — the escrow is correct, only the back-reference failed.
      logger.warn('payouts-request: failed to backfill escrow reference_id', {
        payoutId: payout.id,
        escrowEarningId: escrow.earning_id,
        error: backfillErr.message,
      });
    }

    // 10. Notify the female — best-effort.
    await notify(svc, {
      recipientId: user.id,
      type: 'payout_requested',
      title: 'Payout request submitted',
      body: `Your payout of ${formatPaisa(payoutAmountPaisa)} (${coinsToWithdraw} coins) ` +
        `is being reviewed. Expected within ${rates.processingDays} business days.`,
      data: {
        payout_id: payout.id,
        coins_requested: coinsToWithdraw,
        payout_amount_paisa: payoutAmountPaisa,
      },
    });

    logger.info('Payout requested', {
      payoutId: payout.id,
      femaleId: user.id,
      coinsRequested: coinsToWithdraw,
      payoutAmountPaisa,
    });

    return ok({
      payoutId: payout.id,
      coinsRequested: coinsToWithdraw,
      payoutAmountPaisa,
      payoutAmountFormatted: formatPaisa(payoutAmountPaisa),
      expectedDays: rates.processingDays,
      escrowEarningId: escrow.earning_id,
      requestedAt: payout.requested_at,
    });
  }),
);
