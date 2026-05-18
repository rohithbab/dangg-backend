// End-to-end smoke for the payouts domain.
//   * payouts-request — 6 scenarios incl. math check
//   * payouts-cancel  — 3 scenarios
//   * admin-payouts-action — 8 scenarios (approve / reject / complete / fail
//     happy + missing-arg + non-admin)
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
function mintJwt(userId, phone, role) {
  const now = Math.floor(Date.now() / 1000);
  return signJwt({
    aud: 'authenticated', role: 'authenticated', sub: userId, phone,
    user_metadata: { role }, iat: now, exp: now + 3600,
  });
}
// Admin JWT — sub must reference an actual auth.users row because
// supabase.auth.getUser() inside requireAuth loads the user record.
function mintAdminJwt(adminId, phone) {
  const now = Math.floor(Date.now() / 1000);
  return signJwt({
    aud: 'authenticated', role: 'authenticated',
    sub: adminId, phone,
    user_metadata: { role: 'admin' }, iat: now, exp: now + 3600,
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

let passes = 0, fails = 0;
const report = (label, ok, extra = '') => {
  console.log(`  ${ok ? 'PASS' : 'FAIL'} ${label}${extra ? '  ' + extra : ''}`);
  ok ? passes++ : fails++;
  return ok;
};

const rnd = randomBytes(2).toString('hex');
console.log(`\n=== Provision (suffix ${rnd}) ===`);

// Female with earnings + payout_details
const f = await admin('/auth/v1/admin/users', {
  phone: `+9171${Date.now().toString().slice(-8)}`,
  phone_confirm: true,
  user_metadata: { name: 'Smoke Payout Female', age: 25, role: 'female' },
});
const femaleId = f.body.id;
const femaleJwt = mintJwt(femaleId, f.body.phone, 'female');
console.log(`  female=${femaleId}`);

// Male — needed only so the "no payout_details" smoke step targets a real role mismatch
const m = await admin('/auth/v1/admin/users', {
  phone: `+9172${Date.now().toString().slice(-8)}`,
  phone_confirm: true,
  user_metadata: { name: 'Smoke Payout Male', age: 30, role: 'male' },
});
const maleJwt = mintJwt(m.body.id, m.body.phone, 'male');

// Provision a real admin auth.users row (handle_new_user skips the
// public.users mirror for role='admin' — see migration 20260518240002).
const a = await admin('/auth/v1/admin/users', {
  phone: `+9173${Date.now().toString().slice(-8)}`,
  phone_confirm: true,
  user_metadata: { name: 'Smoke Admin', role: 'admin' },
});
if (a.status >= 400) {
  console.error('Admin user creation failed:', a);
  process.exit(1);
}
const adminId = a.body.id;
const adminJwt = mintAdminJwt(adminId, a.body.phone);
console.log(`  admin=${adminId}`);

// Fund the female via the credit_female_earnings RPC.
await rest('/rest/v1/rpc/credit_female_earnings', {
  p_female_id: femaleId, p_amount: 5000, p_type: 'chat_earning',
  p_reference_id: null, p_description: 'smoke: fund payout',
}, 'POST');

console.log(`\n=== payouts-request — 5 scenarios ===`);

// 1. male caller → 403
report('request rejects male caller', (await callFn('payouts-request', { coinsToWithdraw: 100 }, maleJwt)).status === 403);

// 2. no payout_details → 409
report('request rejects when no payout_details', (await callFn('payouts-request', { coinsToWithdraw: 100 }, femaleJwt)).status === 409);

// Add payout_details so subsequent scenarios get past step 3.
await rest('/rest/v1/payout_details', {
  female_id: femaleId, method: 'upi', upi_id: 'smoke@oksbi',
}, 'POST');

// 3. below MIN_PAYOUT_COINS (default 100) → 400
report('request rejects below MIN_PAYOUT_COINS', (await callFn('payouts-request', { coinsToWithdraw: 50 }, femaleJwt)).status === 400);

// 4. insufficient balance (request 99999, have 5000) → 402
report('request rejects insufficient balance', (await callFn('payouts-request', { coinsToWithdraw: 99999 }, femaleJwt)).status === 402);

// 5. happy path: 500 coins → ₹350.00 (35000 paisa) at default rates
const req5 = await callFn('payouts-request', { coinsToWithdraw: 500 }, femaleJwt);
const payout5 = req5.body?.data;
report('request happy path returns 200', req5.status === 200);
report('  payoutAmountPaisa = 35000 (500 × 100 × 0.70)', payout5?.payoutAmountPaisa === 35000);
report('  payoutAmountFormatted = ₹350.00', payout5?.payoutAmountFormatted === '₹350.00');

// 6. second active payout → 409
report('request rejects 2nd active', (await callFn('payouts-request', { coinsToWithdraw: 200 }, femaleJwt)).status === 409);

console.log(`\n=== payouts-cancel — 3 scenarios ===`);

// 7. happy cancel on the pending request from scenario 5
const cancel = await callFn('payouts-cancel', { payoutId: payout5.payoutId }, femaleJwt);
report('cancel happy path', cancel.status === 200 && cancel.body?.data?.status === 'cancelled');
report('  refundedCoins = 500', cancel.body?.data?.refundedCoins === 500);

// 8. second cancel → 409
report('cancel rejects 2nd transition', (await callFn('payouts-cancel', { payoutId: payout5.payoutId }, femaleJwt)).status === 409);

// 9. cannot cancel an approved payout: create a new pending → admin approve → female cancel attempt
const req9 = (await callFn('payouts-request', { coinsToWithdraw: 200 }, femaleJwt)).body?.data;
await callFn('admin-payouts-action', { payoutId: req9.payoutId, action: 'approve' }, adminJwt);
report('cancel rejects approved payout', (await callFn('payouts-cancel', { payoutId: req9.payoutId }, femaleJwt)).status === 409);

console.log(`\n=== admin-payouts-action — 8 scenarios ===`);

// 10. non-admin caller → 403
report('admin-action rejects non-admin', (await callFn('admin-payouts-action', { payoutId: req9.payoutId, action: 'complete', utrNumber: 'X' }, femaleJwt)).status === 403);

// 11. complete without UTR → 400
report('complete without UTR → 400', (await callFn('admin-payouts-action', { payoutId: req9.payoutId, action: 'complete' }, adminJwt)).status === 400);

// 12. complete with UTR → 200, status=completed
const done = await callFn('admin-payouts-action', { payoutId: req9.payoutId, action: 'complete', utrNumber: 'UTR-SMOKE-001' }, adminJwt);
report('complete with UTR → 200 completed', done.status === 200 && done.body?.data?.status === 'completed');

// Set up a new pending → reject paths.
const req13 = (await callFn('payouts-request', { coinsToWithdraw: 150 }, femaleJwt)).body?.data;

// 13. reject without reason → 400
report('reject without reason → 400', (await callFn('admin-payouts-action', { payoutId: req13.payoutId, action: 'reject' }, adminJwt)).status === 400);

// 14. reject with reason → 200, status=rejected, refunded
const rej = await callFn('admin-payouts-action', { payoutId: req13.payoutId, action: 'reject', rejectionReason: 'Smoke: bad UPI' }, adminJwt);
report('reject with reason → 200 rejected', rej.status === 200 && rej.body?.data?.status === 'rejected');
report('  refundedCoins = 150', rej.body?.data?.refundedCoins === 150);

// Set up a new pending → approve → fail paths.
const req15 = (await callFn('payouts-request', { coinsToWithdraw: 120 }, femaleJwt)).body?.data;
await callFn('admin-payouts-action', { payoutId: req15.payoutId, action: 'approve' }, adminJwt);

// 15. fail without reason → 400
report('fail without reason → 400', (await callFn('admin-payouts-action', { payoutId: req15.payoutId, action: 'fail' }, adminJwt)).status === 400);

// 16. fail with reason → 200, status=failed, refunded
const fail = await callFn('admin-payouts-action', { payoutId: req15.payoutId, action: 'fail', failureReason: 'Smoke: bank bounced' }, adminJwt);
report('fail with reason → 200 failed', fail.status === 200 && fail.body?.data?.status === 'failed');
report('  refundedCoins = 120', fail.body?.data?.refundedCoins === 120);

console.log(`\n=== Math snapshot check ===`);

// Insert a fresh pending of 1000 coins to verify the snapshot fields.
const req17 = (await callFn('payouts-request', { coinsToWithdraw: 1000 }, femaleJwt)).body?.data;
const fetched = await rest(`/rest/v1/payouts?id=eq.${req17.payoutId}&select=coins_requested,coin_value_paisa_snapshot,commission_pct_snapshot,payout_amount_paisa`, null, 'GET');
const row = fetched.body?.[0];
report('1000 coins → 70000 paisa (₹700.00)', row?.payout_amount_paisa === 70000);
report('  coin_value_paisa_snapshot = 100', row?.coin_value_paisa_snapshot === 100);
report('  commission_pct_snapshot = 30', Number(row?.commission_pct_snapshot) === 30);

console.log(`\n=== Result: ${passes} pass, ${fails} fail ===`);
process.exit(fails === 0 ? 0 : 1);
