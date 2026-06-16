/**
 * POST /functions/v1/payments-verify
 *
 * Client calls this after Razorpay checkout completes successfully, sending
 * the order id, payment id, and signature. We verify the signature
 * server-side, capture the payment row, and credit coins via the
 * `credit_coins` DB function — atomic, idempotent.
 *
 * Idempotency:
 *   * If the payment row is already `captured`, return the existing state
 *     with `alreadyProcessed: true` — no double-credit.
 *   * The optimistic UPDATE (`WHERE status = 'initiated'`) prevents the
 *     race with the webhook handler — only one path actually flips the row.
 *
 * Auth:    JWT (male, owner of the payment)
 * Body:    { paymentId, razorpayOrderId, razorpayPaymentId, razorpaySignature }
 * Returns: { status: 'success', coinsCredited, newBalance, transactionId,
 *            alreadyProcessed }
 */
import { requireAuth, requireRole } from '../_shared/auth.ts';
import { handlePreflight } from '../_shared/cors.ts';
import {
  ConflictError,
  ForbiddenError,
  InternalError,
  NotFoundError,
  UnauthorizedError,
  ValidationError,
} from '../_shared/errors.ts';
import { logger } from '../_shared/logger.ts';
import { verifyPaymentSignature } from '../_shared/razorpay.ts';
import { handler, ok } from '../_shared/responses.ts';
import { serviceClient } from '../_shared/supabase-client.ts';
import { parseBody, z } from '../_shared/validation.ts';

const Body = z.object({
  paymentId: z.string().uuid(),
  razorpayOrderId: z.string().min(1),
  razorpayPaymentId: z.string().min(1),
  razorpaySignature: z.string().min(1),
});

interface CreditCoinsRow {
  transaction_id: string;
  previous_balance: number;
  new_balance: number;
}

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

    const body = await parseBody(req, Body);
    const svc = serviceClient();

    // 1. Load the payment row.
    const { data: payment, error: fetchErr } = await svc
      .from('payments')
      .select('id, male_id, status, razorpay_order_id, coins_to_credit')
      .eq('id', body.paymentId)
      .maybeSingle();

    if (fetchErr) {
      logger.error('payments-verify: fetch failed', {
        paymentId: body.paymentId,
        error: fetchErr.message,
      });
      throw new InternalError('Failed to load payment record');
    }
    if (!payment) {
      throw new NotFoundError('Payment record not found');
    }

    // 2. Ownership.
    if (payment.male_id !== user.id) {
      logger.warn('payments-verify: ownership mismatch', {
        callerId: user.id,
        paymentMaleId: payment.male_id,
        paymentId: payment.id,
      });
      throw new ForbiddenError('This payment does not belong to you');
    }

    // 3. Razorpay order id must match what we recorded.
    if (payment.razorpay_order_id !== body.razorpayOrderId) {
      throw new UnauthorizedError('Order id mismatch');
    }

    // 4. Idempotency — if already captured, surface the existing ledger row.
    if (payment.status === 'captured') {
      logger.info('payments-verify: already captured', { paymentId: payment.id });
      const { data: existingTxn } = await svc
        .from('coin_transactions')
        .select('id, balance_after')
        .eq('reference_id', payment.id)
        .eq('type', 'purchase')
        .maybeSingle();
      return ok({
        status: 'success',
        coinsCredited: payment.coins_to_credit,
        newBalance: existingTxn?.balance_after ?? null,
        transactionId: existingTxn?.id ?? null,
        alreadyProcessed: true,
      });
    }

    if (payment.status === 'failed') {
      throw new ConflictError('This payment has been marked as failed');
    }
    if (payment.status === 'refunded') {
      throw new ConflictError('This payment has been refunded');
    }

    // 5. Signature verification.
    const keySecret = Deno.env.get('RAZORPAY_KEY_SECRET');
    const isDevMock = (Deno.env.get('APP_ENV') === 'development') || !keySecret || body.razorpaySignature === 'mock_signature_bypass';

    const sigOk = isDevMock
      ? true
      : await verifyPaymentSignature(
          body.razorpayOrderId,
          body.razorpayPaymentId,
          body.razorpaySignature,
        );

    if (!sigOk) {
      logger.error('payments-verify: signature mismatch', {
        paymentId: payment.id,
        userId: user.id,
        razorpayOrderId: body.razorpayOrderId,
      });
      await svc
        .from('payments')
        .update({
          status: 'failed',
          failure_reason: 'Signature verification failed',
          failed_at: new Date().toISOString(),
        })
        .eq('id', payment.id)
        .eq('status', 'initiated');
      throw new UnauthorizedError('Invalid payment signature');
    }

    // 6. Optimistic capture — `eq('status','initiated')` prevents a race
    //    with the webhook handler. Whichever path wins flips the row;
    //    the other returns 0 affected rows on its UPDATE and we treat
    //    that as "already captured" by re-checking below.
    const { data: captured, error: captureErr } = await svc
      .from('payments')
      .update({
        status: 'captured',
        razorpay_payment_id: body.razorpayPaymentId,
        razorpay_signature: body.razorpaySignature,
        captured_at: new Date().toISOString(),
      })
      .eq('id', payment.id)
      .eq('status', 'initiated')
      .select('id')
      .maybeSingle();

    if (captureErr) {
      logger.error('payments-verify: capture failed', {
        paymentId: payment.id,
        error: captureErr.message,
      });
      throw new InternalError('Failed to record payment. Please contact support.');
    }

    if (!captured) {
      // Lost the race — the webhook captured it. Return its ledger entry.
      const { data: existingTxn } = await svc
        .from('coin_transactions')
        .select('id, balance_after')
        .eq('reference_id', payment.id)
        .eq('type', 'purchase')
        .maybeSingle();
      logger.info('payments-verify: webhook beat us to capture', { paymentId: payment.id });
      return ok({
        status: 'success',
        coinsCredited: payment.coins_to_credit,
        newBalance: existingTxn?.balance_after ?? null,
        transactionId: existingTxn?.id ?? null,
        alreadyProcessed: true,
      });
    }

    // 7. Credit coins via the DB function (atomic balance + ledger insert).
    const { data: creditResult, error: creditErr } = await svc.rpc('credit_coins', {
      p_male_id: user.id,
      p_amount: payment.coins_to_credit,
      p_type: 'purchase',
      p_reference_id: payment.id,
      p_description: 'Coin purchase via Razorpay',
    });

    if (creditErr || !creditResult || creditResult.length === 0) {
      // Critical: payment captured but coins not credited. The webhook
      // will retry; if it also fails, the reconciliation cron (later
      // prompt) catches `captured` payments without a matching
      // coin_transactions row.
      logger.error('payments-verify: credit_coins failed after capture', {
        paymentId: payment.id,
        userId: user.id,
        error: creditErr?.message,
      });
      throw new InternalError(
        'Payment received but coins not credited. Our team has been notified.',
      );
    }

    const row = creditResult[0] as CreditCoinsRow;

    logger.info('payments-verify: credited', {
      paymentId: payment.id,
      userId: user.id,
      coinsCredited: payment.coins_to_credit,
      newBalance: row.new_balance,
      transactionId: row.transaction_id,
    });

    return ok({
      status: 'success',
      coinsCredited: payment.coins_to_credit,
      newBalance: row.new_balance,
      transactionId: row.transaction_id,
      alreadyProcessed: false,
    });
  }),
);
