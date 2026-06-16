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
 * Auth: webhook signature only. JWT verification is disabled in
 * `supabase/config.toml` for this function — the request is server-to-
 * server, so a Supabase JWT would never be present.
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

// --- My Dreams Technology SMS gateway ---
const MYDREAMS_API_KEY = Deno.env.get('MYDREAMS_API_KEY') ?? '';
const MYDREAMS_SENDER_ID = Deno.env.get('MYDREAMS_SENDER_ID') ?? 'MDTDMO';
const MYDREAMS_SMS_ENDPOINT = Deno.env.get('MYDREAMS_SMS_ENDPOINT') ??
  'http://app.mydreamstechnology.in/vb/apikey.php';
// Fills the 2nd `{#var#}` of the DLT-approved template.
const SMS_APP_NAME = Deno.env.get('SMS_APP_NAME') ?? 'Dangg';

const APP_ENV = Deno.env.get('APP_ENV') ?? 'development';
const IS_LOCAL_DEV = APP_ENV === 'development';

// -----------------------------------------------------------------------------
// Body validation — matches Supabase Auth's Send SMS Hook payload.
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
    if (preflight) {
      return preflight;
    }

    if (req.method !== 'POST') {
      throw new ValidationError('Only POST is accepted');
    }

    // Verify env is wired before reading body so misconfig surfaces clearly.
    if (!SEND_SMS_HOOK_SECRET) {
      throw new InternalError('SEND_SMS_HOOK_SECRET is not configured');
    }
    const smsConfigured = Boolean(MYDREAMS_API_KEY);
    // Outside local dev, the SMS gateway is mandatory — a missing key is a
    // real misconfig that must surface, not silently log the OTP.
    if (!smsConfigured && !IS_LOCAL_DEV) {
      throw new InternalError('My Dreams Technology API key is not configured');
    }

    // Read body once as text so we can both verify the signature AND parse.
    const rawBody = await req.text();
    await verifyStandardWebhookSignature(req, rawBody, SEND_SMS_HOOK_SECRET);

    const body = await parseHookBody(rawBody);
    const phone = normalisePhone(body.sms.phone);
    const otp = body.sms.otp;

    logger.info('send-sms-hook received', { userId: body.user.id, phone });

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

    // Supabase ignores the response body for SMS hooks; 2xx = success.
    return ok({ delivered: true });
  }),
);

// =============================================================================
// Helpers
// =============================================================================

/**
 * Verifies the standard-webhooks signature header
 * (https://github.com/standard-webhooks/standard-webhooks) that Supabase
 * sends with every auth hook invocation. Throws `UnauthorizedError` on
 * any failure.
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

  // Reject requests with a timestamp more than 5 minutes from now (replay).
  const tsSeconds = Number.parseInt(timestamp, 10);
  if (!Number.isFinite(tsSeconds)) {
    throw new UnauthorizedError('Invalid webhook timestamp');
  }
  const nowSeconds = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSeconds - tsSeconds) > 5 * 60) {
    throw new UnauthorizedError('Webhook timestamp outside tolerance');
  }

  // Standard-webhooks signing scheme: `${id}.${timestamp}.${rawBody}`.
  // Supabase stores the hook secret as `v1,whsec_<base64>`: a `v1,` version
  // tag followed by the standard-webhooks `whsec_` prefix and the base64 key.
  // Strip both prefixes before decoding the key.
  let cleanedSecret = secret;
  if (cleanedSecret.startsWith('v1,')) {
    cleanedSecret = cleanedSecret.slice('v1,'.length);
  }
  if (cleanedSecret.startsWith('whsec_')) {
    cleanedSecret = cleanedSecret.slice('whsec_'.length);
  }
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

  // The header can carry multiple `v1,...` signatures separated by spaces;
  // any match is OK.
  const sigOk = signature.split(' ').some((s) => timingSafeEqual(s, expected));
  if (!sigOk) {
    throw new UnauthorizedError('Webhook signature mismatch');
  }
}

/** Constant-time string compare to avoid timing-attack leakage. */
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) {
    return false;
  }
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

/** Parse the raw body string against the HookBody schema. */
async function parseHookBody(raw: string): Promise<HookBody> {
  // Wrap as a Request to reuse parseBody's error handling.
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
  const message =
    `Dear ${SMS_APP_NAME}, Your OTP for login is ${otp}. Valid for 5 minutes. ` +
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
