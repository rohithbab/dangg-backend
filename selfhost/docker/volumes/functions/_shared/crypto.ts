/**
 * Crypto primitives shared by signature-verification call sites
 * (Razorpay payment signature, Razorpay webhook signature).
 *
 * Web Crypto (`crypto.subtle`) is available natively in Deno — no third-party
 * crypto library needed.
 */

/**
 * Compute HMAC-SHA256 of `message` keyed by `secret`. Returns lowercase hex.
 *
 * Razorpay's signing scheme is HMAC-SHA256 hex for both payment and webhook
 * signatures — same algorithm, different keys (`KEY_SECRET` vs
 * `WEBHOOK_SECRET`).
 */
export async function hmacSha256Hex(message: string, secret: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(secret) as BufferSource,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signature = await crypto.subtle.sign(
    'HMAC',
    key,
    encoder.encode(message) as BufferSource,
  );
  return Array.from(new Uint8Array(signature))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

/**
 * Constant-time string comparison. Use for EVERY signature / token / secret
 * comparison so attackers can't gradient-descend the correct value via
 * response-time differences.
 */
export function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) {
    return false;
  }
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}
