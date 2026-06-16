/**
 * POST /functions/v1/cloudinary-sign
 *
 * Generic Cloudinary signed-upload primitive. Returns the bundle the
 * client needs to POST an asset directly to Cloudinary without ever
 * routing the file through our Edge Runtime.
 *
 * The caller specifies a `folder`. We enforce an allowlist of folders so
 * an authenticated user can't sign uploads for arbitrary paths (e.g., the
 * private verification-photos bucket is OFF-limits to this generic
 * endpoint — verification flows have their own signed-URL endpoint).
 *
 * Auth: any authenticated user.
 */
import { requireAuth } from '../_shared/auth.ts';
import { signUpload } from '../_shared/cloudinary.ts';
import { handlePreflight } from '../_shared/cors.ts';
import { ValidationError } from '../_shared/errors.ts';
import { logger } from '../_shared/logger.ts';
import { handler, ok } from '../_shared/responses.ts';
import { parseBody, z } from '../_shared/validation.ts';

/**
 * Folders the generic endpoint is allowed to sign for. Adding more folders
 * here is a deliberate decision — review the access model first.
 */
const ALLOWED_FOLDER_PREFIXES = ['profile_pictures/', 'chat_attachments/'] as const;

const Body = z.object({
  folder: z.string().min(1).max(200),
  publicId: z.string().min(1).max(200).optional(),
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

    if (!ALLOWED_FOLDER_PREFIXES.some((p) => input.folder.startsWith(p))) {
      throw new ValidationError(
        `folder must start with one of: ${ALLOWED_FOLDER_PREFIXES.join(', ')}`,
      );
    }

    const signed = await signUpload({ folder: input.folder, publicId: input.publicId ?? null });

    logger.info('cloudinary-sign issued', {
      userId: user.id,
      folder: input.folder,
      publicId: input.publicId ?? null,
    });

    return ok(signed);
  }),
);
