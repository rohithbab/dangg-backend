/**
 * POST /functions/v1/verification-photo-submit
 *
 * Called after a female uploads her verification selfie directly to R2
 * (via a presigned PUT from `media-sign`, category=verification). This endpoint:
 *   1. Validates the R2 object key lives under the caller's own folder.
 *   2. Flips `females.verification_status` to 'pending', stamps
 *      `verification_submitted_at`, and stores the R2 key in
 *      `verification_photo_path`. Admins use the key to fetch a presigned GET.
 *
 * Re-submission is allowed only from 'none' or 'rejected'. A female who is
 * already 'pending' (awaiting review) or 'verified' is rejected with 409.
 *
 * Auth:    JWT (female)
 * Body:    { objectPath: string }   e.g. "verification/photos/<uid>/<uuid>.jpg"
 * Returns: { verificationStatus: 'pending', submittedAt }
 */
import { requireAuth, requireRole } from '../_shared/auth.ts';
import { handlePreflight } from '../_shared/cors.ts';
import { ConflictError, InternalError, NotFoundError, ValidationError } from '../_shared/errors.ts';
import { logger } from '../_shared/logger.ts';
import { handler, ok } from '../_shared/responses.ts';
import { serviceClient } from '../_shared/supabase-client.ts';
import { parseBody, z } from '../_shared/validation.ts';

const Body = z.object({
  /** R2 object key returned by media-sign, e.g. "verification/photos/<uid>/<uuid>.jpg". */
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

    // 2. The R2 key must live under the caller's own folder.
    //    media-sign produces: verification/photos/{uid}/{uuid}.ext
    const expectedPrefix = `verification/photos/${user.id}/`;
    if (!objectPath.startsWith(expectedPrefix)) {
      throw new ValidationError(`objectPath must start with ${expectedPrefix}`);
    }

    const svc = serviceClient();

    // 3. Read current status. Only 'none' / 'rejected' may (re)submit.
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

    // 4. Transition to pending. Store the R2 key so admins can retrieve the
    //    photo. Guard on the prior status so a concurrent submit can't double-apply.
    const submittedAt = new Date().toISOString();
    const { data: updated, error: updateErr } = await svc
      .from('females')
      .update({
        verification_status: 'pending',
        verification_submitted_at: submittedAt,
        verification_rejection_reason: null,
        verification_photo_path: objectPath,
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
