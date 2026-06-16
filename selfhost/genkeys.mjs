// Generates all secrets for the self-hosted Supabase stack.
// ANON_KEY / SERVICE_ROLE_KEY are HS256 JWTs signed with JWT_SECRET — they
// MUST be regenerated together if JWT_SECRET changes.
import crypto from 'node:crypto';

const b64urlJson = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
function jwt(payload, secret) {
  const data = `${b64urlJson({ alg: 'HS256', typ: 'JWT' })}.${b64urlJson(payload)}`;
  const sig = crypto.createHmac('sha256', secret).update(data).digest('base64url');
  return `${data}.${sig}`;
}
// Alphanumeric random of exact length n.
const rand = (n) =>
  crypto.randomBytes(n * 2).toString('base64').replace(/[^a-zA-Z0-9]/g, '').slice(0, n);
const randhex = (n) => crypto.randomBytes(n).toString('hex');

const JWT_SECRET = rand(48);
const iat = Math.floor(Date.now() / 1000);
const exp = iat + 60 * 60 * 24 * 365 * 10; // 10-year keys
const out = {
  JWT_SECRET,
  ANON_KEY: jwt({ role: 'anon', iss: 'supabase', iat, exp }, JWT_SECRET),
  SERVICE_ROLE_KEY: jwt({ role: 'service_role', iss: 'supabase', iat, exp }, JWT_SECRET),
  POSTGRES_PASSWORD: rand(32),
  DASHBOARD_USERNAME: 'dangg_admin',
  DASHBOARD_PASSWORD: rand(20),
  SECRET_KEY_BASE: randhex(32),   // 64 hex chars (Realtime)
  VAULT_ENC_KEY: rand(32),        // exactly 32 chars (Vault)
};
console.log(JSON.stringify(out, null, 2));
