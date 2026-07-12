/**
 * POST /functions/v1/media-sign-read   (your spec's "/media/sign-read")
 *
 * Batch-resolves R2 object KEYS → short-lived presigned GET URLs so the app can
 * display media while `dangg-media` stays FULLY PRIVATE (no public bucket, no
 * r2.dev). Same SigV4/aws4fetch signing as `media-sign` uses for uploads — here
 * we sign GETs. No new env vars, no new bucket.
 *
 * Only the non-sensitive, user-facing prefixes are signable here:
 *   users/profile-images/  users/gallery-images/  chat/images/  chat/videos/
 * verification/photos and reports/evidence are intentionally DROPPED — they are
 * admin-only and read through their own flow, so an end user can never pull
 * sensitive media through this endpoint.
 *
 * Auth:    any authenticated user.
 * Body:    { keys: string[] }   (max 100; blank keys + non-allowlisted prefixes dropped)
 * Returns: { urls: { [key]: signedUrl }, expiresInSeconds }
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

// ~1 hour. The client caches the resulting URLs for slightly less (≈50 min).
const PRESIGN_EXPIRY_SECONDS = 3600;
const MAX_KEYS = 100;

// Only these (non-sensitive) prefixes may be signed for read. Everything else —
// notably verification/photos and reports/evidence — is dropped.
const READABLE_PREFIXES = [
  'users/profile-images/',
  'users/gallery-images/',
  'chat/images/',
  'chat/videos/',
];

const Body = z.object({
  keys: z.array(z.string()).max(MAX_KEYS),
});

function isReadable(key: string): boolean {
  return READABLE_PREFIXES.some((p) => key.startsWith(p));
}

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

    await requireAuth(req);
    const { keys } = await parseBody(req, Body);

    // Normalize: trim, drop blanks, dedupe, keep only signable prefixes.
    const wanted = [...new Set(keys.map((k) => k.trim()).filter(Boolean))].filter(isReadable);

    const client = new AwsClient({
      accessKeyId: R2_ACCESS_KEY_ID,
      secretAccessKey: R2_SECRET_ACCESS_KEY,
      service: 's3',
      region: 'auto',
    });

    // signQuery=true → auth moves into the URL query (a presigned URL).
    const urls: Record<string, string> = {};
    await Promise.all(
      wanted.map(async (key) => {
        const objectUrl = `${R2_S3_ENDPOINT}/${R2_BUCKET_NAME}/${key}`;
        try {
          const signed = await client.sign(
            `${objectUrl}?X-Amz-Expires=${PRESIGN_EXPIRY_SECONDS}`,
            { method: 'GET', aws: { signQuery: true } },
          );
          urls[key] = signed.url;
        } catch (cause) {
          // Skip just this key; the client renders a placeholder for it.
          logger.error('media-sign-read: presign failed', { key, error: String(cause) });
        }
      }),
    );

    logger.info('media-sign-read issued', { requested: keys.length, signed: Object.keys(urls).length });

    return ok({ urls, expiresInSeconds: PRESIGN_EXPIRY_SECONDS });
  }),
);
