/**
 * POST /functions/v1/profile-picture-upload
 *
 * Returns Cloudinary signed-upload params scoped to the calling user's
 * profile-picture folder. The client then POSTs the image directly to
 * Cloudinary (no proxy through us), then calls `profile-picture-confirm`
 * with the resulting URL.
 *
 * Auth: any authenticated user.
 *
 * Why a wrapper around `cloudinary-sign`? This endpoint enforces the
 * folder (`profile_pictures/<userId>`) so the caller can't sign uploads
 * to someone else's profile-picture folder.
 */
import { requireAuth } from '../_shared/auth.ts';
import { signUpload } from '../_shared/cloudinary.ts';
import { handlePreflight } from '../_shared/cors.ts';
import { ValidationError } from '../_shared/errors.ts';
import { logger } from '../_shared/logger.ts';
import { handler, ok } from '../_shared/responses.ts';

Deno.serve(
  handler(async (req: Request): Promise<Response> => {
    const preflight = handlePreflight(req);
    if (preflight) {
      return preflight;
    }

    if (req.method !== 'POST') {
      throw new ValidationError('Only POST is accepted');
    }

    const user = await requireAuth(req);
    const folder = `profile_pictures/${user.id}`;
    // Using a fixed publicId so each new upload overwrites the previous
    // one — Cloudinary's `invalidate: true` could be set client-side if
    // CDN cache freshness matters.
    const publicId = 'avatar';

    const signed = await signUpload({ folder, publicId });

    logger.info('profile-picture-upload issued', { userId: user.id, folder });

    return ok(signed);
  }),
);
