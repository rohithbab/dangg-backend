/**
 * POST /functions/v1/payments-create-order
 *
 * Initiates a Razorpay order for a coin-package purchase. Returns the
 * data the mobile checkout SDK needs to open Razorpay's payment sheet.
 *
 * Flow:
 *   1. Auth — caller must be male.
 *   2. Validate input — packageId is a UUID.
 *   3. Load package via the calling user's client (RLS filters to active).
 *   4. INSERT into `payments` (service role) with a placeholder
 *      razorpay_order_id; this gives us an internal `paymentId` to pass
 *      to Razorpay as `receipt`.
 *   5. Call Razorpay /orders REST API.
 *   6. Patch the payment row with the real Razorpay order id.
 *   7. Return the bundle for the mobile SDK.
 *
 * Auth:    JWT (male)
 * Body:    { packageId: uuid }
 * Returns: { paymentId, razorpayOrderId, amount, currency, razorpayKeyId,
 *            packageName, totalCoins }
 */
import { requireAuth, requireRole } from '../_shared/auth.ts';
import { handlePreflight } from '../_shared/cors.ts';
import { ConflictError, InternalError, NotFoundError, ValidationError } from '../_shared/errors.ts';
import { logger } from '../_shared/logger.ts';
import { createRazorpayOrder, getRazorpayKeyId } from '../_shared/razorpay.ts';
import { handler, ok } from '../_shared/responses.ts';
import { serviceClient, userClient } from '../_shared/supabase-client.ts';
import { parseBody, z } from '../_shared/validation.ts';

const Body = z.object({
  packageId: z.string().uuid(),
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

    // 1. Auth: male only.
    const user = await requireAuth(req);
    requireRole(user, 'male');

    // 2. Input.
    const { packageId } = await parseBody(req, Body);

    // 3. Load the package via the user's client — RLS keeps inactive ones hidden.
    const userDb = userClient(req);
    const { data: pkg, error: pkgErr } = await userDb
      .from('coin_packages')
      .select('id, name, coins, bonus_coins, total_coins, price_paisa, is_active')
      .eq('id', packageId)
      .maybeSingle();

    if (pkgErr) {
      logger.error('Failed to load coin package', {
        packageId,
        userId: user.id,
        error: pkgErr.message,
      });
      throw new InternalError('Failed to load coin package');
    }
    if (!pkg) {
      throw new NotFoundError('Coin package not found or no longer available');
    }
    if (!pkg.is_active) {
      throw new ConflictError('This coin package is no longer available');
    }

    // 4. Reserve a payments row first so we have a stable internal id to
    //    pass to Razorpay as `receipt`. The placeholder order id is
    //    namespaced so it can't collide with a real Razorpay id later.
    const svc = serviceClient();
    const placeholderOrderId = `pending_${crypto.randomUUID()}`;

    const { data: paymentRow, error: insertErr } = await svc
      .from('payments')
      .insert({
        male_id: user.id,
        package_id: pkg.id,
        razorpay_order_id: placeholderOrderId,
        amount_paisa: pkg.price_paisa,
        coins_to_credit: pkg.total_coins,
        status: 'initiated',
      })
      .select('id')
      .single();

    if (insertErr || !paymentRow) {
      logger.error('Failed to create payment row', {
        userId: user.id,
        packageId: pkg.id,
        error: insertErr?.message,
      });
      throw new InternalError('Failed to initiate payment. Please try again.');
    }

    // 5. Talk to Razorpay. If this fails, mark the row failed so we don't
    //    leak orphaned 'initiated' payments.
    let order;
    try {
      order = await createRazorpayOrder(pkg.price_paisa, paymentRow.id, {
        male_id: user.id,
        package_id: pkg.id,
        payment_id: paymentRow.id,
      });
    } catch (cause) {
      await svc
        .from('payments')
        .update({
          status: 'failed',
          failure_reason: 'Razorpay order creation failed',
          failed_at: new Date().toISOString(),
        })
        .eq('id', paymentRow.id);
      throw cause;
    }

    // 6. Patch with the real order id.
    const { error: patchErr } = await svc
      .from('payments')
      .update({ razorpay_order_id: order.id })
      .eq('id', paymentRow.id);

    if (patchErr) {
      logger.error('Failed to patch payment with razorpay order id', {
        paymentId: paymentRow.id,
        razorpayOrderId: order.id,
        error: patchErr.message,
      });
      throw new InternalError('Payment initiation issue. Please try again.');
    }

    logger.info('Razorpay order created', {
      paymentId: paymentRow.id,
      razorpayOrderId: order.id,
      userId: user.id,
      packageId: pkg.id,
      amountPaisa: pkg.price_paisa,
    });

    return ok({
      paymentId: paymentRow.id,
      razorpayOrderId: order.id,
      amount: order.amount,
      currency: order.currency,
      razorpayKeyId: getRazorpayKeyId(),
      packageName: pkg.name,
      totalCoins: pkg.total_coins,
    });
  }),
);
