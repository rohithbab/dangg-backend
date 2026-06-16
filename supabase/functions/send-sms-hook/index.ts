/**
 * POST /functions/v1/send-sms-hook
 *
 * Supabase Auth's "Send SMS Hook" webhook. Supabase calls this whenever it
 * needs to deliver an OTP — both at signup and at login. The body shape is:
 *
 *   {
 *     "user":  { ... },
 *     "sms":   { "otp": "123456", "phone": "+919876543210" }
 *   }
 *
 * We verify the standard-webhooks signature header against the shared
 * `SEND_SMS_HOOK_SECRET`, then proxy the OTP to My Dreams Technology.
 * On any failure we return a non-2xx so Supabase surfaces the error.
 *
 * Auth: webhook signature only — no Supabase JWT on server-to-server calls.
 */
import { handlePreflight } from '../_shared/cors.ts';
import {
  InternalError,
  ServiceUnavailableError,
  UnauthorizedError,
  ValidationError,
} from '../_shared/errors.ts';
import { logger } from '../_shared/logger.ts';
import { handler, ok } from '../_shared/responses.ts';
import { parseBody, z } from '../_shared/validation.ts';

// -----------------------------------------------------------------------------
// Env
// -----------------------------------------------------------------------------
const SEND_SMS_HOOK_SECRET = Deno.env.get('SEND_SMS_HOOK_SECRET') ?? '';
const MYDREAMS_API_KEY = Deno.env.get('MYDREAMS_API_KEY') ?? '';
const MYDREAMS_SENDER_ID = Deno.env.get('MYDREAMS_SENDER_ID') ?? '';
const MYDREAMS_SMS_ENDPOINT =
  Deno.env.get('MYDREAMS_SMS_ENDPOINT') ?? 'http://app.mydreamstechnology.in/vb/apikey.php';
const SMS_APP_NAME = Deno.env.get('SMS_APP_NAME') ?? 'User';

const APP_ENV = Deno.env.get('APP_ENV') ?? 'development';
const IS_LOCAL_DEV = APP_ENV === 'development';

// -----------------------------------------------------------------------------
// Body schema — matches Supabase Auth's Send SMS Hook payload.
// -----------------------------------------------------------------------------
const HookBody = z.object({
  user: z.object({
    id: z.string(),
    phone: z.string().optional(),
  }).passthrough(),
  sms: z.object({
    otp: z.string().min(4).max(8),
    phone: z.string().min(8),
  }),
});

type HookBody = z.infer<typeof HookBody>;

Deno.serve(
  handler(async (req: Request): Promise<Response> => {
    const preflight = handlePreflight(req);
    if (preflight) return preflight;

    if (req.method !== 'POST') {
      throw new ValidationError('Only POST is accepted');
    }

    if (!SEND_SMS_HOOK_SECRET) {
      throw new InternalError('SEND_SMS_HOOK_SECRET is not configured');
    }

    const smsConfigured = Boolean(MYDREAMS_API_KEY && MYDREAMS_SENDER_ID);
    if (!smsConfigured && !IS_LOCAL_DEV) {
      throw new InternalError('MyDreams SMS credentials are not configured');
    }

    const rawBody = await req.text();
    await verifyStandardWebhookSignature(req, rawBody, SEND_SMS_HOOK_SECRET);

    const body = await parseHookBody(rawBody);
    const phone = normalisePhone(body.sms.phone);
    const otp = body.sms.otp;

    logger.info('send-sms-hook received', { userId: body.user.id, phone });

    if (!smsConfigured) {
      logger.warn('LOCAL DEV: MyDreams not configured — OTP not sent. Use this code.', {
        userId: body.user.id,
        phone,
        otp,
      });
      return ok({ delivered: false, devOtp: otp });
    }

    await deliverViaMyDreams(phone, otp);

    logger.info('OTP delivered via MyDreams', { userId: body.user.id, phone });

    return ok({ delivered: true });
  }),
);

// =============================================================================
// Helpers
// =============================================================================

/**
 * Verifies the standard-webhooks signature Supabase sends with every auth
 * hook invocation. Throws `UnauthorizedError` on any failure.
 */
async function verifyStandardWebhookSignature(
  req: Request,
  rawBody: string,
  secret: string,
): Promise<void> {
  const id = req.headers.get('webhook-id');
  const timestamp = req.headers.get('webhook-timestamp');
  const signature = req.headers.get('webhook-signature');

  if (!id || !timestamp || !signature) {
    throw new UnauthorizedError('Missing webhook-* headers');
  }

  const tsSeconds = Number.parseInt(timestamp, 10);
  if (!Number.isFinite(tsSeconds)) {
    throw new UnauthorizedError('Invalid webhook timestamp');
  }
  const nowSeconds = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSeconds - tsSeconds) > 5 * 60) {
    throw new UnauthorizedError('Webhook timestamp outside tolerance');
  }

  let cleanedSecret = secret;
  if (cleanedSecret.startsWith('v1,')) cleanedSecret = cleanedSecret.slice('v1,'.length);
  if (cleanedSecret.startsWith('whsec_')) cleanedSecret = cleanedSecret.slice('whsec_'.length);

  let keyBytes: Uint8Array;
  try {
    keyBytes = Uint8Array.from(atob(cleanedSecret), (c) => c.charCodeAt(0));
  } catch {
    throw new InternalError('SEND_SMS_HOOK_SECRET is not valid base64');
  }

  const key = await crypto.subtle.importKey(
    'raw',
    keyBytes as BufferSource,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signedPayload = new TextEncoder().encode(`${id}.${timestamp}.${rawBody}`);
  const computed = new Uint8Array(
    await crypto.subtle.sign('HMAC', key, signedPayload as BufferSource),
  );
  const expected = `v1,${btoa(String.fromCharCode(...computed))}`;

  const sigOk = signature.split(' ').some((s) => timingSafeEqual(s, expected));
  if (!sigOk) {
    throw new UnauthorizedError('Webhook signature mismatch');
  }
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function parseHookBody(raw: string): Promise<HookBody> {
  const req = new Request('http://internal/parse', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: raw,
  });
  return await parseBody(req, HookBody);
}

/** Strip non-digits — MyDreams expects numbers only (no leading +). */
function normalisePhone(phone: string): string {
  return phone.replace(/[^0-9]/g, '');
}

/**
 * Sends OTP via My Dreams Technology's HTTP API.
 * Endpoint: GET /vb/apikey.php?apikey=KEY&senderid=ID&number=PHONE&message=MSG&app=APP&format=json
 */
async function deliverViaMyDreams(phone: string, otp: string): Promise<void> {
  const message = `Your Dangg verification code is ${otp}. Valid for 10 minutes. Do not share.`;

  const params = new URLSearchParams({
    apikey: MYDREAMS_API_KEY,
    senderid: MYDREAMS_SENDER_ID,
    number: phone,
    message,
    app: SMS_APP_NAME,
    format: 'json',
  });

  const url = `${MYDREAMS_SMS_ENDPOINT}?${params.toString()}`;

  let response: Response;
  try {
    response = await fetch(url, { method: 'GET' });
  } catch (cause) {
    logger.error('MyDreams network failure', { error: String(cause) });
    throw new ServiceUnavailableError('SMS provider unreachable');
  }

  if (!response.ok) {
    const text = await response.text().catch(() => '<unreadable>');
    logger.error('MyDreams non-2xx response', {
      status: response.status,
      body: text.slice(0, 500),
    });
    throw new ServiceUnavailableError(`SMS provider rejected the request (${response.status})`);
  }

  const text = await response.text().catch(() => '');
  logger.info('MyDreams response', { body: text.slice(0, 200) });
}
