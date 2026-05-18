/**
 * POST /functions/v1/webhooks-razorpay
 *
 * Razorpay → backend webhook for payment events. Configured in the
 * Razorpay dashboard with the signing secret stored in
 * `RAZORPAY_WEBHOOK_SECRET`.
 *
 * Events handled today:
 *   * payment.captured  — ensure coins are credited (idempotent with payments-verify)
 *   * payment.failed    — mark the payment row as failed
 *   * refund.processed  — debit coins from the male's wallet
 *
 * Other event types are acknowledged (200) but not processed.
 *
 * Auth: signature verification via the `X-Razorpay-Signature` header
 *       (no Supabase JWT).
 *
 * Response policy:
 *   * 2xx tells Razorpay "delivered, no retry needed".
 *   * 5xx asks Razorpay to retry — we use this on processing errors so the
 *     event lives in `webhook_events` with `processing_error` set, and the
 *     next retry can recover.
 *   * 401 on signature failure surfaces the misconfiguration in Razorpay's
 *     monitoring dashboard.
 */
import type { SupabaseClient } from '@supabase/supabase-js';
import { corsHeaders } from '../_shared/cors.ts';
import { logger } from '../_shared/logger.ts';
import { verifyWebhookSignature } from '../_shared/razorpay.ts';
import { serviceClient } from '../_shared/supabase-client.ts';

const jsonHeaders = { ...corsHeaders, 'Content-Type': 'application/json' } as const;

interface RazorpayPaymentEntity {
  id: string;
  order_id: string;
  amount: number;
  currency: string;
  status: string;
  error_description?: string;
  error_reason?: string;
}

interface RazorpayRefundEntity {
  id: string;
  payment_id: string;
  amount: number;
  status: string;
}

interface RazorpayWebhookEvent {
  event: string;
  created_at: number;
  payload: {
    payment?: { entity: RazorpayPaymentEntity };
    refund?: { entity: RazorpayRefundEntity };
  };
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), { status, headers: jsonHeaders });
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: corsHeaders });
  }
  if (req.method !== 'POST') {
    return jsonResponse({ ok: false, error: 'Method not allowed' }, 405);
  }

  // 1. Raw body — signature is computed over the EXACT bytes Razorpay sent.
  const rawBody = await req.text();

  // 2. Signature header.
  const signature = req.headers.get('X-Razorpay-Signature');
  if (!signature) {
    logger.warn('Razorpay webhook missing signature header');
    return jsonResponse({ ok: false, error: 'Missing signature' }, 401);
  }

  let signatureValid: boolean;
  try {
    signatureValid = await verifyWebhookSignature(rawBody, signature);
  } catch (cause) {
    // verifyWebhookSignature throws if the secret env var is missing.
    logger.error('Razorpay webhook signature verification errored', {
      error: cause instanceof Error ? cause.message : String(cause),
    });
    return jsonResponse({ ok: false, error: 'Internal error' }, 500);
  }
  if (!signatureValid) {
    logger.error('Razorpay webhook signature invalid', {
      signaturePrefix: signature.slice(0, 8),
    });
    return jsonResponse({ ok: false, error: 'Invalid signature' }, 401);
  }

  // 3. Parse the body.
  let event: RazorpayWebhookEvent;
  try {
    event = JSON.parse(rawBody) as RazorpayWebhookEvent;
  } catch {
    return jsonResponse({ ok: false, error: 'Invalid JSON body' }, 400);
  }

  const svc = serviceClient();

  // 4. Idempotency: Razorpay's webhooks don't always carry a top-level
  //    event id, so we synthesise one from the event type and the inner
  //    entity id. Two deliveries of the same event end up with the same key.
  const innerEntityId = event.payload.payment?.entity.id ??
    event.payload.refund?.entity.id ??
    `${event.event}-${event.created_at}`;
  const eventKey = `${event.event}::${innerEntityId}`;

  const { data: webhookRow, error: insertErr } = await svc
    .from('webhook_events')
    .insert({
      provider: 'razorpay',
      event_id: eventKey,
      event_type: event.event,
      payload: event,
    })
    .select('id')
    .maybeSingle();

  if (insertErr) {
    // 23505 = unique_violation → duplicate event, ack and skip.
    if (insertErr.code === '23505') {
      logger.info('Duplicate Razorpay webhook ignored', { eventKey });
      return jsonResponse({ ok: true, duplicate: true }, 200);
    }
    logger.error('Failed to insert webhook_events row', {
      eventKey,
      error: insertErr.message,
    });
    return jsonResponse({ ok: false, error: 'Internal error' }, 500);
  }
  if (!webhookRow) {
    logger.error('webhook_events insert returned no row', { eventKey });
    return jsonResponse({ ok: false, error: 'Internal error' }, 500);
  }

  // 5. Dispatch.
  try {
    switch (event.event) {
      case 'payment.captured':
        await handlePaymentCaptured(svc, event);
        break;
      case 'payment.failed':
        await handlePaymentFailed(svc, event);
        break;
      case 'refund.processed':
        await handleRefundProcessed(svc, event);
        break;
      default:
        logger.info('Razorpay webhook ignored (event type not handled)', {
          eventType: event.event,
        });
    }

    await svc
      .from('webhook_events')
      .update({ processed_at: new Date().toISOString() })
      .eq('id', webhookRow.id);

    logger.info('Razorpay webhook processed', { eventType: event.event, eventKey });
    return jsonResponse({ ok: true }, 200);
  } catch (cause) {
    const errorMessage = cause instanceof Error ? cause.message : String(cause);
    logger.error('Razorpay webhook processing failed', {
      eventType: event.event,
      eventKey,
      error: errorMessage,
    });
    await svc
      .from('webhook_events')
      .update({ processing_error: errorMessage })
      .eq('id', webhookRow.id);
    // 5xx asks Razorpay to retry — the next delivery clears the error.
    return jsonResponse({ ok: false, error: 'Processing failed' }, 500);
  }
});

// ============================================================================
// Event handlers
// ============================================================================

async function handlePaymentCaptured(
  svc: SupabaseClient,
  event: RazorpayWebhookEvent,
): Promise<void> {
  const payment = event.payload.payment?.entity;
  if (!payment) {
    throw new Error('payment.captured event missing payment entity');
  }

  const { data: paymentRecord, error } = await svc
    .from('payments')
    .select('id, male_id, status, coins_to_credit')
    .eq('razorpay_order_id', payment.order_id)
    .maybeSingle();

  if (error) {
    throw new Error(`Failed to load payment for order ${payment.order_id}: ${error.message}`);
  }
  if (!paymentRecord) {
    throw new Error(`Payment record not found for order ${payment.order_id}`);
  }

  if (paymentRecord.status === 'captured') {
    logger.info('Webhook: payment already captured', { paymentId: paymentRecord.id });
    return;
  }
  if (paymentRecord.status !== 'initiated') {
    logger.warn('Webhook: payment in unexpected state, skipping capture', {
      paymentId: paymentRecord.id,
      status: paymentRecord.status,
    });
    return;
  }

  // Optimistic capture. Whichever path (verify EF or webhook) wins this
  // UPDATE actually flips the row; the other returns zero rows.
  const { data: captured, error: captureErr } = await svc
    .from('payments')
    .update({
      status: 'captured',
      razorpay_payment_id: payment.id,
      captured_at: new Date().toISOString(),
    })
    .eq('id', paymentRecord.id)
    .eq('status', 'initiated')
    .select('id')
    .maybeSingle();

  if (captureErr) {
    throw new Error(`Failed to update payment to captured: ${captureErr.message}`);
  }
  if (!captured) {
    // Lost the race — verify already captured it and credited coins.
    logger.info('Webhook: verify beat us to capture', { paymentId: paymentRecord.id });
    return;
  }

  const { error: creditErr } = await svc.rpc('credit_coins', {
    p_male_id: paymentRecord.male_id,
    p_amount: paymentRecord.coins_to_credit,
    p_type: 'purchase',
    p_reference_id: paymentRecord.id,
    p_description: 'Coin purchase via Razorpay (webhook)',
  });

  if (creditErr) {
    throw new Error(`Failed to credit coins after webhook capture: ${creditErr.message}`);
  }
}

async function handlePaymentFailed(
  svc: SupabaseClient,
  event: RazorpayWebhookEvent,
): Promise<void> {
  const payment = event.payload.payment?.entity;
  if (!payment) {
    throw new Error('payment.failed event missing payment entity');
  }

  const reason = payment.error_description ?? payment.error_reason ?? 'Unknown';

  const { error } = await svc
    .from('payments')
    .update({
      status: 'failed',
      failure_reason: reason,
      failed_at: new Date().toISOString(),
    })
    .eq('razorpay_order_id', payment.order_id)
    .eq('status', 'initiated');

  if (error) {
    throw new Error(`Failed to mark payment failed: ${error.message}`);
  }
}

async function handleRefundProcessed(
  svc: SupabaseClient,
  event: RazorpayWebhookEvent,
): Promise<void> {
  const refund = event.payload.refund?.entity;
  if (!refund) {
    throw new Error('refund.processed event missing refund entity');
  }

  const { data: paymentRecord, error: fetchErr } = await svc
    .from('payments')
    .select('id, male_id, coins_to_credit, status')
    .eq('razorpay_payment_id', refund.payment_id)
    .maybeSingle();

  if (fetchErr) {
    throw new Error(`Failed to load payment for refund: ${fetchErr.message}`);
  }
  if (!paymentRecord) {
    throw new Error(`Refund: payment not found for payment_id=${refund.payment_id}`);
  }
  if (paymentRecord.status === 'refunded') {
    logger.info('Refund: already marked refunded', { paymentId: paymentRecord.id });
    return;
  }

  const { error: updateErr } = await svc
    .from('payments')
    .update({ status: 'refunded', refunded_at: new Date().toISOString() })
    .eq('id', paymentRecord.id);

  if (updateErr) {
    throw new Error(`Failed to mark refunded: ${updateErr.message}`);
  }

  // Debit the coins. If balance is insufficient (male already spent them)
  // credit_coins raises check_violation; we log + return without rethrowing
  // so the webhook itself succeeds (no infinite retry on a known edge case).
  const { error: debitErr } = await svc.rpc('credit_coins', {
    p_male_id: paymentRecord.male_id,
    p_amount: -paymentRecord.coins_to_credit,
    p_type: 'razorpay_refund',
    p_reference_id: paymentRecord.id,
    p_description: 'Refund processed via Razorpay',
  });

  if (debitErr) {
    if (debitErr.message?.includes('Insufficient coin balance')) {
      logger.warn('Refund: insufficient balance for full deduction', {
        paymentId: paymentRecord.id,
        coinsToDeduct: paymentRecord.coins_to_credit,
      });
      // TODO partial-deduction policy lives in the admin/reconciliation prompt.
      return;
    }
    throw new Error(`Failed to debit coins for refund: ${debitErr.message}`);
  }
}
