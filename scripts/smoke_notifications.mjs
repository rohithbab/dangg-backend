// Smoke test for the notifications wiring on the chat-request flow.
// Exercises every Phase-1 trigger:
//   1. send             → female gets chat_request_received
//   2. respond(accept)  → male gets chat_request_accepted
//   3. respond(decline) → male gets chat_request_declined
//   4. cancel           → female gets chat_request_cancelled
//   5. expire (cron)    → male gets chat_request_expired, female gets chat_request_missed
//   6. RLS — recipient can mark-read; tampering with title is blocked
import { createHmac, randomBytes } from 'node:crypto';

const SUPABASE_URL = 'http://127.0.0.1:54321';
const JWT_SECRET = 'super-secret-jwt-token-with-at-least-32-characters-long';
const SERVICE_KEY =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU';

function b64url(buf) {
  return Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function signJwt(payload) {
  const h = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const p = b64url(JSON.stringify(payload));
  const sig = b64url(createHmac('sha256', JWT_SECRET).update(`${h}.${p}`).digest());
  return `${h}.${p}.${sig}`;
}
function mintUserJwt(userId, phone, role) {
  const now = Math.floor(Date.now() / 1000);
  return signJwt({
    aud: 'authenticated', role: 'authenticated', sub: userId, phone,
    user_metadata: { role }, iat: now, exp: now + 3600,
  });
}

async function admin(path, body, method = 'POST') {
  const r = await fetch(`${SUPABASE_URL}${path}`, {
    method,
    headers: { 'Content-Type': 'application/json', apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
    body: body ? JSON.stringify(body) : undefined,
  });
  const t = await r.text();
  let j; try { j = JSON.parse(t); } catch { j = t; }
  return { status: r.status, body: j };
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
  const t = await r.text();
  let j; try { j = JSON.parse(t); } catch { j = t; }
  return { status: r.status, body: j };
}
async function callFn(name, body, jwt) {
  const r = await fetch(`${SUPABASE_URL}/functions/v1/${name}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${jwt}` },
    body: JSON.stringify(body ?? {}),
  });
  const t = await r.text();
  let j; try { j = JSON.parse(t); } catch { j = t; }
  return { status: r.status, body: j };
}

async function countNotifs(userId, type, jwt) {
  // Service-role list (filtered to one user) keeps the smoke deterministic.
  const r = await rest(
    `/rest/v1/notifications?recipient_id=eq.${userId}&type=eq.${type}&select=id,title,body,data,is_read`,
    null, 'GET');
  return r.body;
}

function report(label, ok, info = '') {
  console.log(`  ${ok ? 'PASS' : 'FAIL'} ${label}${info ? '  ' + info : ''}`);
  return ok;
}
let passes = 0, fails = 0;
const tally = (ok) => ok ? passes++ : fails++;

const tag = randomBytes(2).toString('hex');
console.log(`\n=== Provision users (tag ${tag}) ===`);
const m = await admin('/auth/v1/admin/users', {
  phone: `+9192${Date.now().toString().slice(-8)}`,
  phone_confirm: true,
  user_metadata: { name: 'Smoke Male', age: 30, role: 'male' },
});
const f = await admin('/auth/v1/admin/users', {
  phone: `+9193${Date.now().toString().slice(-8)}`,
  phone_confirm: true,
  user_metadata: { name: 'Smoke Female', age: 25, role: 'female' },
});
const maleId = m.body.id, femaleId = f.body.id;
console.log(`  male=${maleId}\n  female=${femaleId}`);

await rest(`/rest/v1/males?id=eq.${maleId}`, { coin_balance: 1000 }, 'PATCH');
await rest(`/rest/v1/females?id=eq.${femaleId}`, {
  verification_status: 'verified', is_online: true, coin_price: 50,
}, 'PATCH');

const maleJwt = mintUserJwt(maleId, m.body.phone, 'male');
const femaleJwt = mintUserJwt(femaleId, f.body.phone, 'female');

console.log(`\n=== Scenario 1: send → chat_request_received ===`);
const sent1 = await callFn('chat-requests-send', { femaleId }, maleJwt);
const cr1 = sent1.body?.data?.chatRequestId;
const recv = await countNotifs(femaleId, 'chat_request_received');
tally(report('female has 1 chat_request_received', recv.length === 1, `body="${recv[0]?.body}"`));
tally(report('  payload includes chat_request_id', recv[0]?.data?.chat_request_id === cr1));
tally(report('  payload includes from_user_name', recv[0]?.data?.from_user_name === 'Smoke Male'));

console.log(`\n=== Scenario 2: accept → chat_request_accepted ===`);
await callFn('chat-requests-respond', { chatRequestId: cr1, action: 'accept' }, femaleJwt);
const acc = await countNotifs(maleId, 'chat_request_accepted');
tally(report('male has 1 chat_request_accepted', acc.length === 1, `body="${acc[0]?.body}"`));

console.log(`\n=== Scenario 3: decline → chat_request_declined ===`);
const sent2 = await callFn('chat-requests-send', { femaleId }, maleJwt);
await callFn('chat-requests-respond', { chatRequestId: sent2.body?.data?.chatRequestId, action: 'decline' }, femaleJwt);
const dec = await countNotifs(maleId, 'chat_request_declined');
tally(report('male has 1 chat_request_declined', dec.length === 1, `body="${dec[0]?.body}"`));

console.log(`\n=== Scenario 4: cancel → chat_request_cancelled ===`);
const sent3 = await callFn('chat-requests-send', { femaleId }, maleJwt);
await callFn('chat-requests-cancel', { chatRequestId: sent3.body?.data?.chatRequestId }, maleJwt);
const can = await countNotifs(femaleId, 'chat_request_cancelled');
tally(report('female has 1 chat_request_cancelled', can.length === 1, `body="${can[0]?.body}"`));

console.log(`\n=== Scenario 5: expiry cron → expired + missed ===`);
// Build a past-expiry pending request directly via PostgREST + SQL through pg-meta is not available.
// Use a service-role RPC trick: charge via credit_coins RPC (returns transaction_id),
// then insert chat_requests row with past expires_at, then invoke the cron function.
const charge = await rest(`/rest/v1/rpc/credit_coins`, {
  p_male_id: maleId, p_amount: -75, p_type: 'chat_charge',
  p_reference_id: null, p_description: 'smoke: cron pre-charge',
}, 'POST');
const chargeTxn = charge.body?.[0]?.transaction_id;

const sentPast = new Date(Date.now() - 10 * 60 * 1000).toISOString();
const expiredAt = new Date(Date.now() - 8 * 60 * 1000).toISOString();
await rest(`/rest/v1/chat_requests`, {
  male_id: maleId, female_id: femaleId, chat_cost_coins: 75,
  sent_at: sentPast, expires_at: expiredAt, charge_transaction_id: chargeTxn,
}, 'POST');

// Trigger the cron function manually via RPC.
const sweep = await rest(`/rest/v1/rpc/expire_pending_chat_requests`, {}, 'POST');
tally(report('cron returned expired_count>=1', sweep.body >= 1, `returned=${sweep.body}`));

const exp = await countNotifs(maleId, 'chat_request_expired');
const miss = await countNotifs(femaleId, 'chat_request_missed');
tally(report('male has 1 chat_request_expired', exp.length === 1, `body="${exp[0]?.body}"`));
tally(report('female has 1 chat_request_missed', miss.length === 1, `body="${miss[0]?.body}"`));

console.log(`\n=== Scenario 6: RLS mark-read works; title tamper blocked ===`);
// Read with female JWT, mark as read.
const ownRead = await rest(
  `/rest/v1/notifications?type=eq.chat_request_received&select=id,is_read`,
  null, 'GET', femaleJwt);
const notifId = ownRead.body?.[0]?.id;
const markRead = await rest(
  `/rest/v1/notifications?id=eq.${notifId}`,
  { is_read: true, read_at: new Date().toISOString() }, 'PATCH', femaleJwt);
tally(report('female can mark-read her own notification',
  markRead.status === 200 && markRead.body?.[0]?.is_read === true,
  `status=${markRead.status}`));

// Try tampering with title — should be rejected by RLS WITH CHECK (42501).
const tamper = await rest(
  `/rest/v1/notifications?id=eq.${notifId}`,
  { title: 'HACKED' }, 'PATCH', femaleJwt);
tally(report('RLS WITH CHECK blocks title tamper (42501)',
  tamper.status === 403 || tamper.status === 401 || JSON.stringify(tamper.body).includes('42501')
  || JSON.stringify(tamper.body).includes('row-level security'),
  `status=${tamper.status} body=${JSON.stringify(tamper.body).slice(0, 140)}`));

console.log(`\n=== Result: ${passes} pass, ${fails} fail ===`);
process.exit(fails === 0 ? 0 : 1);
