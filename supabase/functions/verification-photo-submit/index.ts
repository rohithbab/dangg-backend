/**
 * POST /functions/v1/verification-photo-submit
 *
 * Called after a female uploads her verification selfie directly to the
 * private `verification` Storage bucket (under her own
 * `photos/{auth.uid()}/…` folder, enforced by storage RLS). This endpoint:
 *   1. Validates the object path lives under the caller's own folder.
 *   2. Confirms the object actually exists in the bucket.
 *   3. Flips `females.verification_status` to 'pending' and stamps
 *      `verification_submitted_at`. Admins poll the pending queue to review.
 *
 * Re-submission is allowed only from 'none' or 'rejected'. A female who is
 * already 'pending' (awaiting review) or 'verified' is rejected with 409.
 *
 * Auth:    JWT (female)
 * Body:    { objectPath: string }   e.g. "photos/<uid>/selfie.jpg"
 * Returns: { verificationStatus: 'pending', submittedAt }
 */
import { requireAuth, requireRole } from '../_shared/auth.ts';
import { handlePreflight } from '../_shared/cors.ts';
import { ConflictError, InternalError, NotFoundError, ValidationError } from '../_shared/errors.ts';
import { logger } from '../_shared/logger.ts';
import { handler, ok } from '../_shared/responses.ts';
import { serviceClient } from '../_shared/supabase-client.ts';
import { parseBody, z } from '../_shared/validation.ts';

const BUCKET = 'verification';

const Body = z.object({
  /** Storage object path the client uploaded to, e.g. "photos/<uid>/selfie.jpg". */
  objectPath: z.string().min(3).max(300),
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

    // 1. Auth — must be a female.
    const user = await requireAuth(req);
    requireRole(user, 'female');

    const { objectPath } = await parseBody(req, Body);

    // 2. The path must live under the caller's own folder. Storage RLS
    //    already enforces this on upload, but re-validate here so a client
    //    can't submit someone else's object reference.
    const expectedPrefix = `photos/${user.id}/`;
    if (!objectPath.startsWith(expectedPrefix)) {
      throw new ValidationError(`objectPath must live under ${expectedPrefix}`);
    }

    const svc = serviceClient();

    // 3. Confirm the object actually exists in the bucket before we move the
    //    account into 'pending' — otherwise an admin opens an empty review.
    const folder = `photos/${user.id}`;
    const fileName = objectPath.slice(expectedPrefix.length);
    const { data: listing, error: listErr } = await svc.storage
      .from(BUCKET)
      .list(folder, { search: fileName });

    if (listErr) {
      logger.error('verification-photo-submit: storage list failed', {
        userId: user.id,
        error: listErr.message,
      });
      throw new InternalError('Could not verify the uploaded photo');
    }
    const exists = (listing ?? []).some((o) => o.name === fileName);
    if (!exists) {
      throw new NotFoundError('Uploaded photo not found. Please upload again.');
    }

    // 4. Read current status. Only 'none' / 'rejected' may (re)submit.
    const { data: female, error: femaleErr } = await svc
      .from('females')
      .select('verification_status')
      .eq('id', user.id)
      .maybeSingle();

    if (femaleErr) {
      logger.error('verification-photo-submit: female lookup failed', {
        userId: user.id,
        error: femaleErr.message,
      });
      throw new InternalError('Could not load your profile');
    }
    if (!female) {
      throw new NotFoundError('Female profile not found');
    }
    const status = female.verification_status as string;
    if (status === 'pending') {
      throw new ConflictError('Your verification is already under review.');
    }
    if (status === 'verified') {
      throw new ConflictError('Your account is already verified.');
    }

    // 5. Transition to pending. Clear any prior rejection reason so a
    //    re-submit starts clean. Guard on the prior status so a concurrent
    //    submit can't double-apply.
    const submittedAt = new Date().toISOString();
    const { data: updated, error: updateErr } = await svc
      .from('females')
      .update({
        verification_status: 'pending',
        verification_submitted_at: submittedAt,
        verification_rejection_reason: null,
      })
      .eq('id', user.id)
      .in('verification_status', ['none', 'rejected'])
      .select('id, verification_status, verification_submitted_at')
      .maybeSingle();

    if (updateErr) {
      logger.error('verification-photo-submit: status update failed', {
        userId: user.id,
        error: updateErr.message,
      });
      throw new InternalError('Could not submit your verification');
    }
    if (!updated) {
      // Lost the race — another submit already moved it out of none/rejected.
      throw new ConflictError('Your verification is already under review.');
    }

    logger.info('verification photo submitted', {
      userId: user.id,
      objectPath,
    });

    return ok({
      verificationStatus: updated.verification_status,
      submittedAt: updated.verification_submitted_at,
    });
  }),
);
