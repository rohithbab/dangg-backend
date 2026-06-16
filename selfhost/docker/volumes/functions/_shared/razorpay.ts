/**
 * Razorpay helpers — order creation + signature verification.
 *
 * Three secrets, three uses:
 *   * RAZORPAY_KEY_ID         — public-ish; the mobile checkout SDK needs it.
 *   * RAZORPAY_KEY_SECRET     — server-side only. HTTP Basic auth to the
 *                               Razorpay REST API + payment signature HMAC key.
 *   * RAZORPAY_WEBHOOK_SECRET — server-side only. Webhook signature HMAC key.
 *                               This is DIFFERENT from the API secret and is
 *                               configured per-webhook in the Razorpay dashboard.
 *
 * Never log secrets. Log the order id, payment id, request id — never the key.
 */
import { constantTimeEqual, hmacSha256Hex } from './crypto.ts';
import { InternalError, ServiceUnavailableError } from './errors.ts';
import { logger } from './logger.ts';

const RAZORPAY_KEY_ID = Deno.env.get('RAZORPAY_KEY_ID') ?? '';
const RAZORPAY_KEY_SECRET = Deno.env.get('RAZORPAY_KEY_SECRET') ?? '';
const RAZORPAY_WEBHOOK_SECRET = Deno.env.get('RAZORPAY_WEBHOOK_SECRET') ?? '';

const RAZORPAY_ORDERS_ENDPOINT = 'https://api.razorpay.com/v1/orders';

/** Subset of Razorpay's `/v1/orders` response we actually consume. */
export interface RazorpayOrder {
  id: string;
  amount: number;
  amount_paid: number;
  amount_due: number;
  currency: string;
  receipt: string;
  status: 'created' | 'attempted' | 'paid';
  created_at: number;
}

/**
 * Create a Razorpay order via the REST API. Server-only — never invoked
 * from the client because the API secret is needed.
 *
 * `notes` is an arbitrary string map Razorpay echoes back in webhooks; we
 * use it to carry our internal payment id forward.
 */
export async function createRazorpayOrder(
  amountPaisa: number,
  receiptId: string,
  notes: Record<string, string> = {},
): Promise<RazorpayOrder> {
  if (!RAZORPAY_KEY_ID || !RAZORPAY_KEY_SECRET) {
    throw new InternalError('Razorpay credentials not configured');
  }

  const auth = btoa(`${RAZORPAY_KEY_ID}:${RAZORPAY_KEY_SECRET}`);

  let response: Response;
  try {
    response = await fetch(RAZORPAY_ORDERS_ENDPOINT, {
      method: 'POST',
      headers: {
        'Authorization': `Basic ${auth}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        amount: amountPaisa,
        currency: 'INR',
        receipt: receiptId,
        partial_payment: false,
        notes,
      }),
    });
  } catch (cause) {
    logger.error('Razorpay /orders network failure', { error: String(cause), receiptId });
    throw new ServiceUnavailableError('Payment provider unreachable. Please try again.');
  }

  if (!response.ok) {
    const bodyText = await response.text().catch(() => '<unreadable>');
    logger.error('Razorpay /orders non-2xx response', {
      status: response.status,
      receiptId,
      body: bodyText.slice(0, 500),
    });
    throw new ServiceUnavailableError(
      'Payment provider rejected the request. Please try again.',
    );
  }

  return (await response.json()) as RazorpayOrder;
}

/**
 * Verify the signature returned by Razorpay's mobile-SDK callback.
 * Razorpay spec: HMAC-SHA256(`<order_id>|<payment_id>`, KEY_SECRET).
 */
export async function verifyPaymentSignature(
  orderId: string,
  paymentId: string,
  signature: string,
): Promise<boolean> {
  if (!RAZORPAY_KEY_SECRET) {
    throw new InternalError('Razorpay credentials not configured');
  }
  const expected = await hmacSha256Hex(`${orderId}|${paymentId}`, RAZORPAY_KEY_SECRET);
  return constantTimeEqual(expected, signature);
}

/**
 * Verify a Razorpay webhook signature. The signature is computed by
 * Razorpay over the EXACT raw request body using the WEBHOOK secret
 * (different from the API key secret).
 */
export async function verifyWebhookSignature(
  rawBody: string,
  signature: string,
): Promise<boolean> {
  if (!RAZORPAY_WEBHOOK_SECRET) {
    throw new InternalError('Razorpay webhook secret not configured');
  }
  const expected = await hmacSha256Hex(rawBody, RAZORPAY_WEBHOOK_SECRET);
  return constantTimeEqual(expected, signature);
}

/** Returns the public-ish RAZORPAY_KEY_ID for the mobile checkout SDK. */
export function getRazorpayKeyId(): string {
  if (!RAZORPAY_KEY_ID) {
    throw new InternalError('Razorpay key id not configured');
  }
  return RAZORPAY_KEY_ID;
}
