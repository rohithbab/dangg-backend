/**
 * DELETE /functions/v1/profile-picture
 *
 * Removes the caller's profile picture: deletes the asset from Cloudinary
 * AND clears `users.profile_picture_url`. Idempotent — calling on a user
 * with no picture is a no-op success.
 *
 * Auth: any authenticated user.
 *
 * Why DELETE method?
 *   Matches REST semantics — the asset's URL goes from "set" → "unset".
 *   Inventory documents this endpoint as DELETE; client uses
 *   `supabase.functions.invoke(..., { method: 'DELETE' })`.
 */
import { requireAuth } from '../_shared/auth.ts';
import { destroyAsset, extractPublicIdFromUrl } from '../_shared/cloudinary.ts';
import { handlePreflight } from '../_shared/cors.ts';
import { NotFoundError, ValidationError } from '../_shared/errors.ts';
import { logger } from '../_shared/logger.ts';
import { handler, ok } from '../_shared/responses.ts';
import { serviceClient } from '../_shared/supabase-client.ts';

Deno.serve(
  handler(async (req: Request): Promise<Response> => {
    const preflight = handlePreflight(req);
    if (preflight) {
      return preflight;
    }

    if (req.method !== 'DELETE') {
      throw new ValidationError('Only DELETE is accepted');
    }

    const user = await requireAuth(req);
    const db = serviceClient();

    const { data: row, error: selectErr } = await db
      .from('users')
      .select('profile_picture_url')
      .eq('id', user.id)
      .maybeSingle();

    if (selectErr) {
      logger.error('profile-picture delete select failed', {
        userId: user.id,
        error: selectErr.message,
      });
      throw new ValidationError('Failed to read current profile picture');
    }
    if (!row) {
      throw new NotFoundError('User row not found');
    }

    const currentUrl = (row as { profile_picture_url: string | null }).profile_picture_url;
    if (!currentUrl) {
      // Idempotent — nothing to delete.
      logger.info('profile-picture delete no-op (no picture)', { userId: user.id });
      return ok({ profilePictureUrl: null });
    }

    const publicId = extractPublicIdFromUrl(currentUrl);
    if (publicId) {
      // Best-effort Cloudinary delete. If it fails we still clear the DB
      // column — orphan assets are tolerable; a stale DB pointer is worse.
      try {
        await destroyAsset(publicId);
      } catch (e) {
        logger.warn('Cloudinary destroy failed; clearing DB anyway', {
          userId: user.id,
          publicId,
          error: e instanceof Error ? e.message : String(e),
        });
      }
    }

    const { error: updErr } = await db
      .from('users')
      .update({ profile_picture_url: null })
      .eq('id', user.id);

    if (updErr) {
      logger.error('profile-picture delete clear failed', {
        userId: user.id,
        error: updErr.message,
      });
      throw new ValidationError('Failed to clear profile picture');
    }

    logger.info('profile-picture deleted', { userId: user.id });

    return ok({ profilePictureUrl: null });
  }),
);
