/**
 * POST /functions/v1/waitlist-submit
 *
 * Public endpoint — no JWT required (FUNCTIONS_VERIFY_JWT=false).
 * Accepts an email + phone, validates them server-side, and inserts
 * a row into waitlist_users via PostgREST directly (no npm imports).
 *
 * Body:    { email: string, phone: string }
 * Returns: { ok: true }
 */
import { handlePreflight } from '../_shared/cors.ts';
import { ConflictError, ValidationError } from '../_shared/errors.ts';
import { logger } from '../_shared/logger.ts';
import { handler, ok } from '../_shared/responses.ts';

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const PHONE_RE = /^\d{7,15}$/;

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

Deno.serve(
  handler(async (req: Request): Promise<Response> => {
    const preflight = handlePreflight(req);
    if (preflight) return preflight;

    if (req.method !== 'POST') {
      throw new ValidationError('Only POST is accepted');
    }

    let body: { email?: unknown; phone?: unknown };
    try {
      body = await req.json();
    } catch {
      throw new ValidationError('Request body must be valid JSON');
    }

    if (typeof body.email !== 'string' || !body.email.trim()) {
      throw new ValidationError('email is required');
    }
    if (typeof body.phone !== 'string' || !body.phone.trim()) {
      throw new ValidationError('phone is required');
    }

    const normalizedEmail = body.email.trim().toLowerCase();
    const normalizedPhone = body.phone.replace(/[\s\-().+]/g, '');

    if (!EMAIL_RE.test(normalizedEmail)) {
      throw new ValidationError('Invalid email address');
    }
    if (!PHONE_RE.test(normalizedPhone)) {
      throw new ValidationError('Invalid phone number');
    }

    const res = await fetch(`${SUPABASE_URL}/rest/v1/waitlist_users`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'apikey': SERVICE_KEY,
        'Authorization': `Bearer ${SERVICE_KEY}`,
        'Prefer': 'return=minimal',
      },
      body: JSON.stringify({ email: normalizedEmail, phone: normalizedPhone }),
    });

    if (!res.ok) {
      const errBody = await res.text();
      // 409 = unique constraint violation
      if (res.status === 409) {
        throw new ConflictError('You are already on the waitlist.');
      }
      logger.error('waitlist-submit: insert failed', { status: res.status, body: errBody });
      throw new Error('Failed to join waitlist. Please try again.');
    }

    logger.info('Waitlist signup', { email: normalizedEmail });
    return ok({ ok: true });
  }),
);
