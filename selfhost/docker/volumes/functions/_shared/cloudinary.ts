/**
 * Cloudinary signed-upload + asset-destroy helpers.
 *
 * Cloudinary's signed-upload flow keeps the API secret server-side: the
 * client receives a signature, timestamp, API key, and the cloud's upload
 * URL, then uploads the file directly to Cloudinary (no proxy traffic
 * through our Edge Functions). The destroy API likewise needs a server-
 * signed request.
 *
 * Signature spec (HMAC-SHA1):
 *   sorted_params_string + API_SECRET
 *
 * where sorted_params_string is `k1=v1&k2=v2&...` with keys sorted ASCII
 * ascending, omitting `file`, `cloud_name`, `api_key`, `resource_type`,
 * and `signature` itself.
 *
 * Reference:
 *   https://cloudinary.com/documentation/signatures
 *   https://cloudinary.com/documentation/image_upload_api_reference
 */
import { InternalError, ServiceUnavailableError } from './errors.ts';
import { logger } from './logger.ts';

const CLOUDINARY_CLOUD_NAME = Deno.env.get('CLOUDINARY_CLOUD_NAME') ?? '';
const CLOUDINARY_API_KEY = Deno.env.get('CLOUDINARY_API_KEY') ?? '';
const CLOUDINARY_API_SECRET = Deno.env.get('CLOUDINARY_API_SECRET') ?? '';

/** Result of signing an upload — pass the entire object to the client. */
export interface SignedUploadParams {
  cloudName: string;
  apiKey: string;
  timestamp: number;
  folder: string;
  publicId: string | null;
  signature: string;
  /** Endpoint the client POSTs the file to. */
  uploadUrl: string;
}

/**
 * Validates Cloudinary env vars are present. Throws a clear server-side
 * error rather than letting the signed request fail at Cloudinary later.
 */
function assertCloudinaryConfigured(): void {
  if (!CLOUDINARY_CLOUD_NAME || !CLOUDINARY_API_KEY || !CLOUDINARY_API_SECRET) {
    throw new InternalError('Cloudinary credentials are not configured');
  }
}

/**
 * Sign an upload request. Returns the bundle the client needs to POST the
 * file directly to Cloudinary's upload endpoint.
 */
export async function signUpload(opts: {
  folder: string;
  publicId?: string | null;
}): Promise<SignedUploadParams> {
  assertCloudinaryConfigured();

  const timestamp = Math.floor(Date.now() / 1000);
  const paramsToSign: Record<string, string | number> = {
    folder: opts.folder,
    timestamp,
  };
  if (opts.publicId) {
    paramsToSign.public_id = opts.publicId;
  }

  const signature = await sha1Hex(
    stringifyParamsForSigning(paramsToSign) + CLOUDINARY_API_SECRET,
  );

  return {
    cloudName: CLOUDINARY_CLOUD_NAME,
    apiKey: CLOUDINARY_API_KEY,
    timestamp,
    folder: opts.folder,
    publicId: opts.publicId ?? null,
    signature,
    uploadUrl: `https://api.cloudinary.com/v1_1/${CLOUDINARY_CLOUD_NAME}/image/upload`,
  };
}

/**
 * Permanently delete an asset by its `public_id`. Use after the user
 * removes a profile picture or when cleaning up orphaned uploads.
 *
 * Throws `ServiceUnavailableError` if Cloudinary returns a non-2xx.
 */
export async function destroyAsset(publicId: string): Promise<void> {
  assertCloudinaryConfigured();

  const timestamp = Math.floor(Date.now() / 1000);
  const signature = await sha1Hex(
    stringifyParamsForSigning({ public_id: publicId, timestamp }) + CLOUDINARY_API_SECRET,
  );

  const url = `https://api.cloudinary.com/v1_1/${CLOUDINARY_CLOUD_NAME}/image/destroy`;
  const body = new URLSearchParams({
    public_id: publicId,
    api_key: CLOUDINARY_API_KEY,
    timestamp: String(timestamp),
    signature,
  });

  let response: Response;
  try {
    response = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body,
    });
  } catch (cause) {
    logger.error('Cloudinary destroy network failure', { error: String(cause), publicId });
    throw new ServiceUnavailableError('Cloudinary unreachable');
  }

  if (!response.ok) {
    const text = await response.text().catch(() => '<unreadable>');
    logger.error('Cloudinary destroy non-2xx', {
      status: response.status,
      body: text.slice(0, 500),
      publicId,
    });
    throw new ServiceUnavailableError(`Cloudinary rejected destroy (${response.status})`);
  }
}

/**
 * Extract the `public_id` from a Cloudinary delivery URL so we can pass it
 * to `destroyAsset`. Returns null if the URL doesn't look like one of ours.
 *
 * Cloudinary URL shape:
 *   https://res.cloudinary.com/<cloud>/image/upload/v<version>/<folder>/<public_id>.<ext>
 */
export function extractPublicIdFromUrl(url: string): string | null {
  if (!CLOUDINARY_CLOUD_NAME) {
    return null;
  }
  const expectedHost = `res.cloudinary.com`;
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return null;
  }
  if (parsed.hostname !== expectedHost) {
    return null;
  }
  const segments = parsed.pathname.split('/').filter(Boolean);
  // ['<cloud>', 'image', 'upload', 'v<n>', '<folder>...', '<file>.<ext>']
  if (
    segments[0] !== CLOUDINARY_CLOUD_NAME ||
    segments[1] !== 'image' ||
    segments[2] !== 'upload'
  ) {
    return null;
  }
  // Strip the cloud, type, subtype, and version segments.
  let rest = segments.slice(3);
  if (rest.length > 0 && /^v\d+$/.test(rest[0] ?? '')) {
    rest = rest.slice(1);
  }
  if (rest.length === 0) {
    return null;
  }
  // Drop the file extension from the last segment.
  const joined = rest.join('/');
  return joined.replace(/\.[a-zA-Z0-9]+$/, '');
}

/** Returns the configured cloud name — useful for URL validation callers. */
export function cloudinaryCloudName(): string {
  return CLOUDINARY_CLOUD_NAME;
}

// =============================================================================
// Internal helpers
// =============================================================================

/** Serialise params for Cloudinary signing: alphabetical, `&`-joined. */
function stringifyParamsForSigning(params: Record<string, string | number>): string {
  return Object.keys(params)
    .sort()
    .map((key) => `${key}=${params[key]}`)
    .join('&');
}

/** Computes HMAC-SHA1 over the input string and returns lowercase hex. */
async function sha1Hex(input: string): Promise<string> {
  // Cloudinary's spec is hex-encoded SHA1 of (sortedParams + apiSecret) using
  // a single string, NOT keyed HMAC. crypto.subtle.digest gives a plain hash;
  // that's what we want here.
  const data = new TextEncoder().encode(input);
  const digest = new Uint8Array(
    await crypto.subtle.digest('SHA-1', data as BufferSource),
  );
  return Array.from(digest)
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}
