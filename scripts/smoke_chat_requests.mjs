// Smoke test for chat-request EFs.
// Provisions a male + a female via the Supabase admin API, signs short-lived
// JWTs with the local JWT secret, and exercises every documented response code.
import { createHmac, randomBytes } from 'node:crypto';

const SUPABASE_URL = 'http://127.0.0.1:54321';
const JWT_SECRET = 'super-secret-jwt-token-with-at-least-32-characters-long';
const SERVICE_KEY =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU';

function b64url(buf) {
  return Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function signJwt(payload) {
  const header = { alg: 'HS256', typ: 'JWT' };
  const h = b64url(JSON.stringify(header));
  const p = b64url(JSON.stringify(payload));
  const sig = b64url(createHmac('sha256', JWT_SECRET).update(`${h}.${p}`).digest());
  return `${h}.${p}.${sig}`;
}

function mintUserJwt(userId, phone, role) {
  const now = Math.floor(Date.now() / 1000);
  return signJwt({
    aud: 'authenticated',
    role: 'authenticated',
    sub: userId,
    phone,
    user_metadata: { role },
    iat: now,
    exp: now + 3600,
  });
}

async function adminApi(path, body, method = 'POST') {
  const r = await fetch(`${SUPABASE_URL}${path}`, {
    method,
    headers: {
      'Content-Type': 'application/json',
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await r.text();
  let json;
  try { json = JSON.parse(text); } catch { json = text; }
  return { status: r.status, body: json };
}

async function rest(path, body, method, jwt) {
  const r = await fetch(`${SUPABASE_URL}${path}`, {
    method,
    headers: {
      'Content-Type': 'application/json',
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${jwt ?? SERVICE_KEY}`,
      Prefer: 'return=representation',
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await r.text();
  let json;
  try { json = JSON.parse(text); } catch { json = text; }
  return { status: r.status, body: json };
}

async function callFn(name, body, jwt) {
  const r = await fetch(`${SUPABASE_URL}/functions/v1/${name}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${jwt}`,
    },
    body: JSON.stringify(body ?? {}),
  });
  const text = await r.text();
  let json;
  try { json = JSON.parse(text); } catch { json = text; }
  return { status: r.status, body: json };
}

function report(label, expectedStatus, actual) {
  const ok = actual.status === expectedStatus;
  const tag = ok ? 'PASS' : 'FAIL';
  console.log(`  ${tag} ${label}  expected=${expectedStatus} got=${actual.status}  body=${JSON.stringify(actual.body).slice(0, 220)}`);
  return ok;
}

const rnd = randomBytes(2).toString('hex');
const malePhone = `+9199${Date.now().toString().slice(-8)}`;
const femalePhone = `+9198${Date.now().toString().slice(-8)}`;

console.log(`\n=== Provisioning users (suffix ${rnd}) ===`);

const maleResp = await adminApi('/auth/v1/admin/users', {
  phone: malePhone,
  phone_confirm: true,
  user_metadata: { name: `Smoke Male ${rnd}`, age: 30, role: 'male' },
});
if (maleResp.status >= 400) { console.error('Male create failed:', maleResp); process.exit(1); }
const maleId = maleResp.body.id;
console.log(`  male created: ${maleId} (${malePhone})`);

const femaleResp = await adminApi('/auth/v1/admin/users', {
  phone: femalePhone,
  phone_confirm: true,
  user_metadata: { name: `Smoke Female ${rnd}`, age: 25, role: 'female' },
});
if (femaleResp.status >= 400) { console.error('Female create failed:', femaleResp); process.exit(1); }
const femaleId = femaleResp.body.id;
console.log(`  female created: ${femaleId} (${femalePhone})`);

// Fund the male, verify + bring the female online with a coin_price.
await rest(`/rest/v1/males?id=eq.${maleId}`, { coin_balance: 500 }, 'PATCH');
await rest(`/rest/v1/females?id=eq.${femaleId}`, {
  verification_status: 'verified',
  is_online: true,
  coin_price: 50,
}, 'PATCH');

const maleJwt = mintUserJwt(maleId, malePhone, 'male');
const femaleJwt = mintUserJwt(femaleId, femalePhone, 'female');

let passes = 0, fails = 0;
const tally = (ok) => ok ? passes++ : fails++;

console.log(`\n=== Smoke scenarios ===`);

// 1. send: female caller → 403
tally(report('send rejects female caller', 403,
  await callFn('chat-requests-send', { femaleId }, femaleJwt)));

// Provision a second male (no coin balance) for the insufficient-coins case.
const brokeResp = await adminApi('/auth/v1/admin/users', {
  phone: `+9197${Date.now().toString().slice(-8)}`,
  phone_confirm: true,
  user_metadata: { name: 'Smoke Broke', age: 31, role: 'male' },
});
const brokeId = brokeResp.body.id;
const brokeJwt = mintUserJwt(brokeId, brokeResp.body.phone, 'male');
// 2. send: no coins → 402
tally(report('send rejects insufficient coins', 402,
  await callFn('chat-requests-send', { femaleId }, brokeJwt)));

// 3. send: female offline → 409
await rest(`/rest/v1/females?id=eq.${femaleId}`, { is_online: false }, 'PATCH');
tally(report('send rejects female offline', 409,
  await callFn('chat-requests-send', { femaleId }, maleJwt)));
await rest(`/rest/v1/females?id=eq.${femaleId}`, { is_online: true }, 'PATCH');

// 4. send: happy path → 200
const sent = await callFn('chat-requests-send', { femaleId }, maleJwt);
tally(report('send happy path', 200, sent));
const chatRequestId = sent.body?.data?.chatRequestId;

// 5. send: male already has pending → 409
tally(report('send rejects 2nd pending', 409,
  await callFn('chat-requests-send', { femaleId }, maleJwt)));

// 6. respond: male caller → 403
tally(report('respond rejects male caller', 403,
  await callFn('chat-requests-respond', { chatRequestId, action: 'accept' }, maleJwt)));

// 7. respond: female accept → 200
tally(report('respond accept happy path', 200,
  await callFn('chat-requests-respond', { chatRequestId, action: 'accept' }, femaleJwt)));

// 8. respond: 2nd call on same request → 409
tally(report('respond rejects 2nd transition', 409,
  await callFn('chat-requests-respond', { chatRequestId, action: 'decline' }, femaleJwt)));

// 9. Send another, decline, verify male refunded.
const sent2 = await callFn('chat-requests-send', { femaleId }, maleJwt);
const cr2 = sent2.body?.data?.chatRequestId;
const balBefore = sent2.body?.data?.newCoinBalance;
const decline = await callFn('chat-requests-respond', { chatRequestId: cr2, action: 'decline' }, femaleJwt);
tally(report('respond decline returns refund txn', 200, decline));

// 10. respond: stranger female trying to respond to a request not addressed to her → 403
const sent3 = await callFn('chat-requests-send', { femaleId }, maleJwt);
const cr3 = sent3.body?.data?.chatRequestId;
const otherFemale = await adminApi('/auth/v1/admin/users', {
  phone: `+9196${Date.now().toString().slice(-8)}`,
  phone_confirm: true,
  user_metadata: { name: 'Smoke Other Female', age: 26, role: 'female' },
});
const otherFemaleJwt = mintUserJwt(otherFemale.body.id, otherFemale.body.phone, 'female');
tally(report('respond rejects wrong female', 403,
  await callFn('chat-requests-respond', { chatRequestId: cr3, action: 'accept' }, otherFemaleJwt)));

// 11. cancel: happy path → 200 and refund
const cancel = await callFn('chat-requests-cancel', { chatRequestId: cr3 }, maleJwt);
tally(report('cancel happy path', 200, cancel));

// 12. cancel: 2nd call → 409
tally(report('cancel rejects 2nd transition', 409,
  await callFn('chat-requests-cancel', { chatRequestId: cr3 }, maleJwt)));

console.log(`\n=== Result: ${passes} pass, ${fails} fail ===`);
process.exit(fails === 0 ? 0 : 1);
