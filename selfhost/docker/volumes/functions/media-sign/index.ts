/**
 * POST /functions/v1/media-sign
 *
 * Issues a short-lived presigned PUT URL for the Cloudflare R2 bucket
 * (`dangg-media`) so the client uploads files directly to R2 without routing
 * bytes through the Edge Runtime. R2 is S3-compatible; we sign with SigV4 via
 * aws4fetch.
 *
 * The caller picks a `category` from a fixed allowlist; the server owns the
 * object key (always under the caller's own `{uid}/` folder), so a user can
 * never write outside their namespace or into an arbitrary path.
 *
 *   category=profile      → users/profile-images/{uid}/{uuid}.{ext}   (public)
 *   category=gallery      → users/gallery-images/{uid}/{uuid}.{ext}   (public)
 *   category=chat         → chat/{images|videos}/{uid}/{uuid}.{ext}   (public)
 *   category=verification → verification/photos/{uid}/{uuid}.{ext}    (PRIVATE)
 *   category=reports      → reports/evidence/{uid}/{uuid}.{ext}       (PRIVATE)
 *
 * Auth: any authenticated user.
 * Body:    { category, contentType, kind? }
 * Returns: { uploadUrl, objectKey, publicUrl, expiresInSeconds }
 */
import { AwsClient } from 'aws4fetch';

import { requireAuth } from '../_shared/auth.ts';
import { handlePreflight } from '../_shared/cors.ts';
import { InternalError, ValidationError } from '../_shared/errors.ts';
import { logger } from '../_shared/logger.ts';
import { handler, ok } from '../_shared/responses.ts';
import { parseBody, z } from '../_shared/validation.ts';

const R2_ACCOUNT_ID = Deno.env.get('R2_ACCOUNT_ID') ?? '';
const R2_ACCESS_KEY_ID = Deno.env.get('R2_ACCESS_KEY_ID') ?? '';
const R2_SECRET_ACCESS_KEY = Deno.env.get('R2_SECRET_ACCESS_KEY') ?? '';
const R2_BUCKET_NAME = Deno.env.get('R2_BUCKET_NAME') ?? 'dangg-media';
const R2_S3_ENDPOINT = Deno.env.get('R2_S3_ENDPOINT') ??
  (R2_ACCOUNT_ID ? `https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com` : '');
const R2_PUBLIC_BASE_URL = Deno.env.get('R2_PUBLIC_BASE_URL') ?? '';

const PRESIGN_EXPIRY_SECONDS = 300;

// category → key prefix. `chat` splits on `kind` (image vs video).
const PREFIX: Record<string, string> = {
  profile: 'users/profile-images',
  gallery: 'users/gallery-images',
  verification: 'verification/photos',
  reports: 'reports/evidence',
};

// Only these categories are publicly readable; verification/reports stay
// private (served later via a presigned GET, never a public URL).
const PUBLIC_CATEGORIES = new Set(['profile', 'gallery', 'chat']);

// Allowlisted content types → file extension. Anything else is rejected so a
// caller can't smuggle an arbitrary extension into the key.
const EXT_BY_TYPE: Record<string, string> = {
  'image/jpeg': 'jpg',
  'image/jpg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
  'image/heic': 'heic',
  'video/mp4': 'mp4',
  'video/quicktime': 'mov',
  'video/webm': 'webm',
};

const Body = z.object({
  category: z.enum(['profile', 'gallery', 'verification', 'chat', 'reports']),
  contentType: z.string().min(3).max(100),
  // Required only for chat (decides images/ vs videos/).
  kind: z.enum(['image', 'video']).optional(),
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

    if (!R2_ACCESS_KEY_ID || !R2_SECRET_ACCESS_KEY || !R2_S3_ENDPOINT) {
      throw new InternalError('R2 storage is not configured');
    }

    const user = await requireAuth(req);
    const { category, contentType, kind } = await parseBody(req, Body);

    const ext = EXT_BY_TYPE[contentType.toLowerCase()];
    if (!ext) {
      throw new ValidationError(
        `Unsupported contentType. Allowed: ${Object.keys(EXT_BY_TYPE).join(', ')}`,
      );
    }

    // Resolve the key prefix (chat needs a kind).
    let prefix: string;
    if (category === 'chat') {
      const isVideo = kind === 'video' || contentType.startsWith('video/');
      prefix = isVideo ? 'chat/videos' : 'chat/images';
    } else {
      prefix = PREFIX[category];
    }

    // Server owns the key — always namespaced under the caller's uid.
    const objectKey = `${prefix}/${user.id}/${crypto.randomUUID()}.${ext}`;
    const objectUrl = `${R2_S3_ENDPOINT}/${R2_BUCKET_NAME}/${objectKey}`;

    const client = new AwsClient({
      accessKeyId: R2_ACCESS_KEY_ID,
      secretAccessKey: R2_SECRET_ACCESS_KEY,
      service: 's3',
      region: 'auto',
    });

    // signQuery=true → auth moves into the URL query (a presigned URL). Only
    // `host` is signed, so the client PUTs the bytes with its own Content-Type.
    let uploadUrl: string;
    try {
      const signed = await client.sign(`${objectUrl}?X-Amz-Expires=${PRESIGN_EXPIRY_SECONDS}`, {
        method: 'PUT',
        aws: { signQuery: true },
      });
      uploadUrl = signed.url;
    } catch (cause) {
      logger.error('media-sign: presign failed', { error: String(cause) });
      throw new InternalError('Could not sign upload');
    }

    const publicUrl = PUBLIC_CATEGORIES.has(category) && R2_PUBLIC_BASE_URL
      ? `${R2_PUBLIC_BASE_URL.replace(/\/$/, '')}/${objectKey}`
      : null;

    logger.info('media-sign issued', { userId: user.id, category, objectKey });

    return ok({
      uploadUrl,
      objectKey,
      publicUrl,
      expiresInSeconds: PRESIGN_EXPIRY_SECONDS,
    });
  }),
);
