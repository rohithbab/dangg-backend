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
 * `SEND_SMS_HOOK_SECRET`, then deliver the OTP via the My Dreams Technology
 * SMS gateway. On any failure we return a non-2xx so Supabase surfaces the
 * error to the client.
 *
 * TEST NUMBERS: +919000000001–12 never receive real SMS. Instead the hook
 * overwrites the stored OTP hash so that "123456" always validates. This lets
 * the team test the full UI flow without spending SMS credits.
 *
 * Auth: webhook signature only — no Supabase JWT on server-to-server calls.
 */
import { rateLimit } from '../_shared/cache.ts';
import { handlePreflight } from '../_shared/cors.ts';
import {
  InternalError,
  RateLimitError,
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
const MYDREAMS_SENDER_ID = Deno.env.get('MYDREAMS_SENDER_ID') ?? 'MDTDMO';
const MYDREAMS_SMS_ENDPOINT = Deno.env.get('MYDREAMS_SMS_ENDPOINT') ??
  'http://app.mydreamstechnology.in/vb/apikey.php';
const SMS_APP_NAME = Deno.env.get('SMS_APP_NAME') ?? 'Dangg';

const APP_ENV = Deno.env.get('APP_ENV') ?? 'development';
const IS_LOCAL_DEV = APP_ENV === 'development';

// -----------------------------------------------------------------------------
// Test accounts — always pin OTP to TEST_OTP, never send real SMS.
// GoTrue strips the + before storing, so hook may receive either format.
// Enter phone without country code in the app: 9000000001–9000000012.
// -----------------------------------------------------------------------------
const TEST_NUMBERS = new Set([
  '919000000001', '+919000000001',
  '919000000002', '+919000000002',
  '919000000003', '+919000000003',
  '919000000004', '+919000000004',
  '919000000005', '+919000000005',
  '919000000006', '+919000000006',
  '919000000007', '+919000000007',
  '919000000008', '+919000000008',
  '919000000009', '+919000000009',
  '919000000010', '+919000000010',
  '919000000011', '+919000000011',
  '919000000012', '+919000000012',
]);
const TEST_OTP = '123456';

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

    const smsConfigured = Boolean(MYDREAMS_API_KEY);
    if (!smsConfigured && !IS_LOCAL_DEV) {
      throw new InternalError('My Dreams Technology API key is not configured');
    }

    const rawBody = await req.text();
    await verifyStandardWebhookSignature(req, rawBody, SEND_SMS_HOOK_SECRET);

    const body = await parseHookBody(rawBody);
    const otp = body.sms.otp;

    logger.info('send-sms-hook received', { userId: body.user.id, phone: body.sms.phone });

    // Test numbers: pin OTP to 123456 in the DB, skip real SMS entirely.
    // Must happen before rate-limit so repeated test logins aren't throttled.
    if (TEST_NUMBERS.has(body.sms.phone)) {
      await pinTestOtp(body.user.id);
      logger.info('Test number — OTP pinned, SMS skipped', { phone: body.sms.phone });
      return ok({ delivered: true });
    }

    const phone = normalisePhone(body.sms.phone);

    // Rate-limit OTP sends per phone — protects SMS spend + blocks hammering a
    // number. 5 per 15 min covers signup + a few legit resends. Fails OPEN if
    // Redis is down (never blocks a real login on an infra blip).
    const rl = await rateLimit(`otp:${phone}`, 5, 15 * 60);
    if (!rl.allowed) {
      logger.warn('send-sms-hook: OTP rate limit hit', { phone, count: rl.count });
      throw new RateLimitError('Too many OTP requests. Please wait a few minutes and try again.');
    }

    if (!smsConfigured) {
      // Local dev without a real SMS provider: don't fail the auth flow.
      // Log the OTP so the developer can complete signup/login from the
      // edge-runtime logs. NEVER reached in staging/production.
      logger.warn('LOCAL DEV: SMS gateway not configured — OTP not sent. Use this code.', {
        userId: body.user.id,
        phone,
        otp,
      });
      return ok({ delivered: false, devOtp: otp });
    }

    await deliverViaMyDreams(phone, otp);
    logger.info('OTP delivered via My Dreams Technology', { userId: body.user.id, phone });
    return ok({ delivered: true });
  }),
);

// =============================================================================
// Helpers
// =============================================================================

/**
 * For test phone numbers: overwrites the stored OTP hash so that entering
 * TEST_OTP ("123456") always passes GoTrue's OTP verification.
 *
 * Calls pg-meta directly at http://meta:8080/query (internal Docker network).
 * pg-meta requires no HTTP auth for internal requests — auth is handled by
 * Kong for external access only. This avoids Kong/PostgREST circular routing.
 */
async function pinTestOtp(userId: string): Promise<void> {
  // Validate UUID to prevent SQL injection before string interpolation.
  if (!/^[0-9a-f-]{36}$/i.test(userId)) {
    logger.error('pin_test_otp: invalid userId format', { userId });
    return;
  }
  try {
    const res = await fetch('http://meta:8080/query', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        query: `SELECT public.pin_test_otp('${userId}'::uuid, '${TEST_OTP}')`,
      }),
    });
    if (!res.ok) {
      const body = await res.text().catch(() => '');
      logger.error('pin_test_otp pg-meta failed', { status: res.status, body: body.slice(0, 300) });
    }
  } catch (err) {
    logger.error('pin_test_otp fetch error', { error: String(err) });
  }
}

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

/**
 * Convert any incoming phone format to the digits-only national number the
 * gateway docs show. Supabase sends E.164 (`+919876543210`); we strip non-
 * digits and then drop a leading `91` country code so we send the 10-digit
 * form. A bare 10-digit Indian mobile (starts 6–9) is left untouched; only a
 * 12-digit `91…` is trimmed.
 */
function normalisePhone(phone: string): string {
  const digits = phone.replace(/[^0-9]/g, '');
  if (digits.length === 12 && digits.startsWith('91')) {
    return digits.slice(2);
  }
  return digits;
}

/**
 * Delivers the OTP via My Dreams Technology's HTTP SMS API — a GET request
 * with the credentials and message as query params.
 *
 * The message MUST match the DLT-approved template exactly (Welbuilt AI,
 * template id 1707178118046494961) or the operator scrubs it — the gateway
 * still returns "submitted" but the SMS is never delivered. Only the two
 * `{#var#}` slots are filled: var1 = greeting, var2 = the OTP code. All
 * static text + punctuation below is verbatim from the registered template.
 *
 * Throws on a network error, a non-2xx status, or a body that looks like a
 * gateway error (these panels often return 200 + an error string).
 */
async function deliverViaMyDreams(phone: string, otp: string): Promise<void> {
  const message = `Dear ${SMS_APP_NAME}, Your OTP for login is ${otp}. Valid for 5 minutes. ` +
    `Please do not share this OTP - Welbuilt AI Solutions Pvt Ltd.`;

  const params = new URLSearchParams({
    apikey: MYDREAMS_API_KEY,
    senderid: MYDREAMS_SENDER_ID,
    number: phone,
    message,
  });

  const url = `${MYDREAMS_SMS_ENDPOINT}?${params.toString()}`;

  let response: Response;
  try {
    response = await fetch(url, { method: 'GET' });
  } catch (cause) {
    logger.error('My Dreams SMS network failure', { error: String(cause) });
    throw new ServiceUnavailableError('SMS provider unreachable');
  }

  const text = (await response.text().catch(() => '')).trim();

  if (!response.ok) {
    logger.error('My Dreams SMS non-2xx response', {
      status: response.status,
      body: text.slice(0, 500),
    });
    throw new ServiceUnavailableError(`SMS provider rejected the request (${response.status})`);
  }

  // The panel returns HTTP 200 even on logical failures, so inspect the body
  // for obvious error markers. Tune this list once a real success body is seen.
  if (/invalid|error|fail|unauthor|insufficient|not\s+sent/i.test(text)) {
    logger.error('My Dreams SMS error body', { body: text.slice(0, 500) });
    throw new ServiceUnavailableError('SMS provider returned an error');
  }

  logger.info('My Dreams SMS accepted', { body: text.slice(0, 200) });
}
