/**
 * POST /functions/v1/profile-picture-confirm
 *
 * Called after the client uploads an image directly to Cloudinary using
 * the params from `profile-picture-upload`. We:
 *   1. Verify the URL is from our Cloudinary cloud (server-trusted host).
 *   2. Verify the URL's folder matches `profile_pictures/<userId>` so a
 *      malicious client can't link our profile to someone else's asset.
 *   3. Patch `public.users.profile_picture_url` for the calling user.
 *
 * Auth: any authenticated user. The write uses the service client because
 * RLS allows the user to PATCH their own `profile_picture_url` anyway —
 * service-role just avoids a token round-trip and lets us emit a tighter
 * targeted UPDATE.
 */
import { requireAuth } from '../_shared/auth.ts';
import { cloudinaryCloudName, extractPublicIdFromUrl } from '../_shared/cloudinary.ts';
import { handlePreflight } from '../_shared/cors.ts';
import { NotFoundError, ValidationError } from '../_shared/errors.ts';
import { logger } from '../_shared/logger.ts';
import { handler, ok } from '../_shared/responses.ts';
import { serviceClient } from '../_shared/supabase-client.ts';
import { parseBody, z } from '../_shared/validation.ts';

const Body = z.object({
  /** Cloudinary's `secure_url` from the upload response. */
  secureUrl: z.string().url(),
  /** Cloudinary's `public_id` (e.g. `profile_pictures/<userId>/avatar`). */
  publicId: z.string().min(1).max(200),
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

    const user = await requireAuth(req);
    const input = await parseBody(req, Body);

    const expectedFolder = `profile_pictures/${user.id}`;
    if (!input.publicId.startsWith(`${expectedFolder}/`)) {
      throw new ValidationError(
        `publicId must live under ${expectedFolder}/`,
      );
    }

    // Independently re-derive the public id from the URL and require a
    // match. Defends against the client sending a real URL but spoofing
    // the publicId field with someone else's folder.
    const urlPublicId = extractPublicIdFromUrl(input.secureUrl);
    if (!urlPublicId) {
      throw new ValidationError(
        `secureUrl must be a Cloudinary URL for cloud "${cloudinaryCloudName()}"`,
      );
    }
    if (urlPublicId !== input.publicId) {
      throw new ValidationError('publicId does not match secureUrl');
    }

    const db = serviceClient();
    const { data, error } = await db
      .from('users')
      .update({ profile_picture_url: input.secureUrl })
      .eq('id', user.id)
      .select('id, profile_picture_url')
      .single();

    if (error) {
      logger.error('profile-picture-confirm update failed', {
        userId: user.id,
        error: error.message,
      });
      throw new ValidationError('Failed to save profile picture');
    }
    if (!data) {
      throw new NotFoundError('User row not found');
    }

    logger.info('profile-picture-confirm saved', {
      userId: user.id,
      publicId: input.publicId,
    });

    return ok({ profilePictureUrl: data.profile_picture_url });
  }),
);
