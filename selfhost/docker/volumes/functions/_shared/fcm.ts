/**
 * FCM HTTP v1 push sender.
 *
 * Mints a short-lived Google OAuth access token from the service-account JSON
 * (RS256-signed JWT → token endpoint, cached ~1h) and delivers a
 * notification+data message to every device token registered for a user.
 *
 * BEST-EFFORT: never throws to callers. If FCM isn't configured, it's a no-op,
 * so the in-app notification (notify()) keeps working with push dormant.
 *
 * Config (edge-function secrets):
 *   FCM_PROJECT_ID            — Firebase project id
 *   FCM_SERVICE_ACCOUNT_JSON  — full service-account JSON (single line)
 */
import type { SupabaseClient } from '@supabase/supabase-js';
import { logger } from './logger.ts';

const FCM_PROJECT_ID = Deno.env.get('FCM_PROJECT_ID') ?? '';
const FCM_SERVICE_ACCOUNT_JSON = Deno.env.get('FCM_SERVICE_ACCOUNT_JSON') ?? '';

interface ServiceAccount {
  client_email: string;
  private_key: string;
  token_uri?: string;
}

let cachedAccount: ServiceAccount | null = null;
function getAccount(): ServiceAccount | null {
  if (cachedAccount) {
    return cachedAccount;
  }
  if (!FCM_SERVICE_ACCOUNT_JSON) {
    return null;
  }
  try {
    cachedAccount = JSON.parse(FCM_SERVICE_ACCOUNT_JSON) as ServiceAccount;
    return cachedAccount;
  } catch (e) {
    logger.error('fcm: FCM_SERVICE_ACCOUNT_JSON is not valid JSON', { error: String(e) });
    return null;
  }
}

/** True when push delivery is configured (else sends are silent no-ops). */
export function fcmConfigured(): boolean {
  return Boolean(FCM_PROJECT_ID && getAccount());
}

// -- base64url helpers --------------------------------------------------------
function b64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(
    /=+$/,
    '',
  );
}
const b64urlStr = (s: string): string => b64url(new TextEncoder().encode(s));

/** PEM (PKCS#8) → raw DER bytes for crypto.subtle.importKey. */
function pemToDer(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, '')
    .replace(/-----END PRIVATE KEY-----/, '')
    .replace(/\s+/g, '');
  const bin = atob(body);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) {
    out[i] = bin.charCodeAt(i);
  }
  return out;
}

// -- OAuth access-token mint + cache ------------------------------------------
let accessToken: string | null = null;
let accessTokenExp = 0; // epoch seconds

async function getAccessToken(acct: ServiceAccount): Promise<string | null> {
  const now = Math.floor(Date.now() / 1000);
  if (accessToken && now < accessTokenExp - 60) {
    return accessToken;
  }

  const tokenUri = acct.token_uri ?? 'https://oauth2.googleapis.com/token';
  const header = b64urlStr(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claim = b64urlStr(
    JSON.stringify({
      iss: acct.client_email,
      scope: 'https://www.googleapis.com/auth/firebase.messaging',
      aud: tokenUri,
      iat: now,
      exp: now + 3600,
    }),
  );
  const unsigned = `${header}.${claim}`;

  let jwt: string;
  try {
    const key = await crypto.subtle.importKey(
      'pkcs8',
      pemToDer(acct.private_key) as BufferSource,
      { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
      false,
      ['sign'],
    );
    const sig = await crypto.subtle.sign(
      'RSASSA-PKCS1-v1_5',
      key,
      new TextEncoder().encode(unsigned) as BufferSource,
    );
    jwt = `${unsigned}.${b64url(new Uint8Array(sig))}`;
  } catch (e) {
    logger.error('fcm: failed to sign service-account JWT', { error: String(e) });
    return null;
  }

  try {
    const resp = await fetch(tokenUri, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        assertion: jwt,
      }),
    });
    if (!resp.ok) {
      logger.error('fcm: oauth token exchange failed', {
        status: resp.status,
        body: (await resp.text()).slice(0, 200),
      });
      return null;
    }
    const json = (await resp.json()) as { access_token: string; expires_in?: number };
    accessToken = json.access_token;
    accessTokenExp = now + (json.expires_in ?? 3600);
    return accessToken;
  } catch (e) {
    logger.error('fcm: oauth token exchange threw', { error: String(e) });
    return null;
  }
}

export interface PushPayload {
  title: string;
  body: string;
  data?: Record<string, unknown>;
}

/**
 * Delivers a push to every device token registered for `recipientId`.
 * Returns the number delivered. Never throws. Prunes tokens FCM reports as
 * unregistered/invalid so the table self-heals.
 */
export async function sendPushToUser(
  svc: SupabaseClient,
  recipientId: string,
  payload: PushPayload,
): Promise<number> {
  const acct = getAccount();
  if (!acct || !FCM_PROJECT_ID) {
    return 0;
  }

  const { data: rows, error } = await svc
    .from('fcm_tokens')
    .select('token')
    .eq('user_id', recipientId);
  if (error || !rows || rows.length === 0) {
    return 0;
  }

  const token = await getAccessToken(acct);
  if (!token) {
    return 0;
  }

  // FCM data values must be string→string.
  const dataStr: Record<string, string> = {};
  for (const [k, v] of Object.entries(payload.data ?? {})) {
    dataStr[k] = typeof v === 'string' ? v : JSON.stringify(v);
  }

  const endpoint = `https://fcm.googleapis.com/v1/projects/${FCM_PROJECT_ID}/messages:send`;
  let delivered = 0;
  const stale: string[] = [];

  await Promise.all(
    (rows as Array<{ token: string }>).map(async ({ token: deviceToken }) => {
      try {
        const resp = await fetch(endpoint, {
          method: 'POST',
          headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({
            message: {
              token: deviceToken,
              notification: { title: payload.title, body: payload.body },
              data: dataStr,
              android: { priority: 'high' },
              apns: { headers: { 'apns-priority': '10' }, payload: { aps: { sound: 'default' } } },
            },
          }),
        });
        if (resp.ok) {
          delivered++;
          return;
        }
        const text = await resp.text();
        if (resp.status === 404 || /UNREGISTERED|INVALID_ARGUMENT/i.test(text)) {
          stale.push(deviceToken);
        }
        logger.warn('fcm: send non-2xx', { status: resp.status, body: text.slice(0, 160) });
      } catch (e) {
        logger.warn('fcm: send threw', { error: String(e) });
      }
    }),
  );

  if (stale.length > 0) {
    await svc.from('fcm_tokens').delete().in('token', stale).then(
      () => {},
      () => {},
    );
  }

  return delivered;
}
