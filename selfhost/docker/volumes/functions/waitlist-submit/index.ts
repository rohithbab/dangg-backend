/**
 * POST /functions/v1/waitlist-submit
 *
 * Public endpoint — no JWT required (FUNCTIONS_VERIFY_JWT=false).
 * Accepts an email + phone, validates them, and inserts a row into
 * waitlist_users. Duplicate email or phone returns 409.
 *
 * Body:    { email: string, phone: string }
 * Returns: { ok: true }
 */
import { handlePreflight } from '../_shared/cors.ts';
import { ConflictError, ValidationError } from '../_shared/errors.ts';
import { logger } from '../_shared/logger.ts';
import { handler, ok } from '../_shared/responses.ts';
import { serviceClient } from '../_shared/supabase-client.ts';
import { parseBody, z } from '../_shared/validation.ts';

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const PHONE_RE = /^\d{7,15}$/;

const Body = z.object({
  email: z.string().min(1).max(254),
  phone: z.string().min(1).max(20),
});

Deno.serve(
  handler(async (req: Request): Promise<Response> => {
    const preflight = handlePreflight(req);
    if (preflight) return preflight;

    if (req.method !== 'POST') {
      throw new ValidationError('Only POST is accepted');
    }

    const { email, phone } = await parseBody(req, Body);

    const normalizedEmail = email.trim().toLowerCase();
    // Strip spaces, dashes, parentheses, leading +
    const normalizedPhone = phone.replace(/[\s\-().+]/g, '');

    if (!EMAIL_RE.test(normalizedEmail)) {
      throw new ValidationError('Invalid email address');
    }
    if (!PHONE_RE.test(normalizedPhone)) {
      throw new ValidationError('Invalid phone number');
    }

    const svc = serviceClient();

    const { error } = await svc
      .from('waitlist_users')
      .insert({ email: normalizedEmail, phone: normalizedPhone });

    if (error) {
      // 23505 = unique_violation
      if ((error as { code?: string }).code === '23505') {
        throw new ConflictError('You are already on the waitlist.');
      }
      logger.error('waitlist-submit: insert failed', { error: error.message });
      throw new Error('Failed to join waitlist. Please try again.');
    }

    logger.info('Waitlist signup', { email: normalizedEmail });

    return ok({ ok: true });
  }),
);
