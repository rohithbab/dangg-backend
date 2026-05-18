/**
 * CORS headers shared by every Edge Function.
 *
 * The mobile app uses CORS for development from emulators / browsers and
 * the admin dashboard hits these endpoints from a different origin. We
 * allow all origins because every endpoint enforces auth via JWT (or its
 * own webhook signature) — CORS isn't our security boundary.
 */
export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type, x-razorpay-signature',
  'Access-Control-Allow-Methods': 'GET, POST, PATCH, PUT, DELETE, OPTIONS',
  'Access-Control-Max-Age': '86400',
} as const;

/**
 * Short-circuit OPTIONS preflight requests with a 204 response.
 *
 * Call at the top of every Edge Function handler:
 *
 *   const preflight = handlePreflight(req);
 *   if (preflight) return preflight;
 */
export function handlePreflight(req: Request): Response | null {
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: corsHeaders });
  }
  return null;
}
