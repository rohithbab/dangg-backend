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
 * `SEND_SMS_HOOK_SECRET`, then proxy the OTP to MSG91. On any failure we
 * return a non-2xx so Supabase surfaces the error to the client.
 *
 * Auth: webhook signature only. JWT verification is disabled in
 * `supabase/config.toml` for this function — the request is server-to-
 * server, so a Supabase JWT would never be present.
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
const MSG91_AUTH_KEY = Deno.env.get('MSG91_AUTH_KEY') ?? '';
const MSG91_SENDER_ID = Deno.env.get('MSG91_SENDER_ID') ?? '';
const MSG91_OTP_TEMPLATE_ID = Deno.env.get('MSG91_OTP_TEMPLATE_ID') ?? '';

const MSG91_OTP_ENDPOINT = 'https://control.msg91.com/api/v5/otp';

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
    const msg91Configured = Boolean(MSG91_AUTH_KEY && MSG91_OTP_TEMPLATE_ID);
    // Outside local dev, MSG91 is mandatory — a missing key is a real misconfig.
    if (!msg91Configured && !IS_LOCAL_DEV) {
      throw new InternalError('MSG91 credentials are not configured');
    }

    // Read body once as text so we can both verify the signature AND parse.
    const rawBody = await req.text();
    await verifyStandardWebhookSignature(req, rawBody, SEND_SMS_HOOK_SECRET);

    const body = await parseHookBody(rawBody);
    const phone = normalisePhone(body.sms.phone);
    const otp = body.sms.otp;

    logger.info('send-sms-hook received', { userId: body.user.id, phone });

    if (!msg91Configured) {
      // Local dev without a real SMS provider: don't fail the auth flow.
      // Log the OTP so the developer can complete signup/login from the
      // edge-runtime logs. NEVER reached in staging/production.
      logger.warn('LOCAL DEV: MSG91 not configured — OTP not sent. Use this code.', {
        userId: body.user.id,
        phone,
        otp,
      });
      return ok({ delivered: false, devOtp: otp });
    }

    await deliverViaMsg91(phone, otp);

    logger.info('OTP delivered via MSG91', { userId: body.user.id, phone });

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
 * Convert any incoming phone format to the digits-only form MSG91 expects
 * (E.164 with no leading `+`). E.g. `+919876543210` → `919876543210`.
 */
function normalisePhone(phone: string): string {
  return phone.replace(/[^0-9]/g, '');
}

/** Calls MSG91's OTP send endpoint. Throws on non-2xx. */
async function deliverViaMsg91(phone: string, otp: string): Promise<void> {
  const payload: Record<string, string> = {
    mobile: phone,
    template_id: MSG91_OTP_TEMPLATE_ID,
    otp,
  };
  if (MSG91_SENDER_ID) {
    payload.sender = MSG91_SENDER_ID;
  }

  let response: Response;
  try {
    response = await fetch(MSG91_OTP_ENDPOINT, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'authkey': MSG91_AUTH_KEY,
      },
      body: JSON.stringify(payload),
    });
  } catch (cause) {
    logger.error('MSG91 network failure', { error: String(cause) });
    throw new ServiceUnavailableError('SMS provider unreachable');
  }

  if (!response.ok) {
    const text = await response.text().catch(() => '<unreadable>');
    logger.error('MSG91 non-2xx response', {
      status: response.status,
      body: text.slice(0, 500),
    });
    throw new ServiceUnavailableError(`SMS provider rejected the request (${response.status})`);
  }
}
