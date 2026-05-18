// End-to-end smoke for Prompt I (stats + reports + blocks).
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
function mintAdminJwt(id, phone) {
  const now = Math.floor(Date.now() / 1000);
  return signJwt({
    aud: 'authenticated', role: 'authenticated', sub: id, phone,
    user_metadata: { role: 'admin' }, iat: now, exp: now + 3600,
  });
}

async function admin(path, body, method = 'POST') {
  const r = await fetch(`${SUPABASE_URL}${path}`, {
    method,
    headers: { 'Content-Type': 'application/json', apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
    body: body ? JSON.stringify(body) : undefined,
  });
  const t = await r.text(); let j; try { j = JSON.parse(t); } catch { j = t; }
  return { status: r.status, body: j };
}
async function rest(path, body, method, jwt) {
  const r = await fetch(`${SUPABASE_URL}${path}`, {
    method,
    headers: {
      'Content-Type': 'application/json', apikey: SERVICE_KEY,
      Authorization: `Bearer ${jwt ?? SERVICE_KEY}`,
      Prefer: 'return=representation',
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const t = await r.text(); let j; try { j = JSON.parse(t); } catch { j = t; }
  return { status: r.status, body: j };
}
async function callFn(name, body, jwt) {
  const r = await fetch(`${SUPABASE_URL}/functions/v1/${name}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${jwt}` },
    body: JSON.stringify(body ?? {}),
  });
  const t = await r.text(); let j; try { j = JSON.parse(t); } catch { j = t; }
  return { status: r.status, body: j };
}

let passes = 0, fails = 0;
const report = (label, ok, extra = '') => {
  console.log(`  ${ok ? 'PASS' : 'FAIL'} ${label}${extra ? '  ' + extra : ''}`);
  ok ? passes++ : fails++;
  return ok;
};

const tag = randomBytes(2).toString('hex');
console.log(`\n=== Provision users (tag ${tag}) ===`);
const m = await admin('/auth/v1/admin/users', {
  phone: `+9181${Date.now().toString().slice(-8)}`, phone_confirm: true,
  user_metadata: { name: 'Smoke Male', age: 30, role: 'male' },
});
const f1 = await admin('/auth/v1/admin/users', {
  phone: `+9182${Date.now().toString().slice(-8)}`, phone_confirm: true,
  user_metadata: { name: 'Smoke Female 1', age: 25, role: 'female' },
});
const f2 = await admin('/auth/v1/admin/users', {
  phone: `+9183${Date.now().toString().slice(-8)}`, phone_confirm: true,
  user_metadata: { name: 'Smoke Female 2', age: 27, role: 'female' },
});
const a = await admin('/auth/v1/admin/users', {
  phone: `+9184${Date.now().toString().slice(-8)}`, phone_confirm: true,
  user_metadata: { name: 'Smoke Admin', role: 'admin' },
});
const maleId = m.body.id, f1Id = f1.body.id, f2Id = f2.body.id, adminId = a.body.id;
const maleJwt = mintJwt(maleId, m.body.phone, 'male');
const f1Jwt = mintJwt(f1Id, f1.body.phone, 'female');
const adminJwt = mintAdminJwt(adminId, a.body.phone);
console.log(`  male=${maleId}\n  f1=${f1Id}\n  f2=${f2Id}\n  admin=${adminId}`);

// Fund male + verify both females + give f1 coin_price
await rest(`/rest/v1/males?id=eq.${maleId}`, { coin_balance: 1000 }, 'PATCH');
await rest(`/rest/v1/females?id=eq.${f1Id}`,
  { verification_status: 'verified', is_online: true, coin_price: 50 }, 'PATCH');
await rest(`/rest/v1/females?id=eq.${f2Id}`,
  { verification_status: 'verified', is_online: true, coin_price: 60 }, 'PATCH');

// ============================================================================
console.log(`\n=== SECTION A — STATS ===`);
// ============================================================================

// 1. stats-female rejects male
report('stats-female rejects male caller (403)',
  (await callFn('stats-female', {}, maleJwt)).status === 403);

// 2. stats-male rejects female
report('stats-male rejects female caller (403)',
  (await callFn('stats-male', {}, f1Jwt)).status === 403);

// 3. stats-female returns shaped object for an empty female
const sf = await callFn('stats-female', {}, f1Jwt);
const sfd = sf.body?.data;
report('stats-female returns 200 with shaped payload', sf.status === 200 && sfd
  && 'balance' in sfd && 'earnings' in sfd && 'requests' in sfd
  && 'profile' in sfd && 'recent_activity' in sfd);
report('  stats-female balance.earnings_balance_coins = 0', sfd?.balance?.earnings_balance_coins === 0);
report('  stats-female requests.total_received = 0', sfd?.requests?.total_received === 0);

// 4. stats-male returns shaped object for a funded-but-no-activity male
const sm = await callFn('stats-male', {}, maleJwt);
const smd = sm.body?.data;
report('stats-male returns 200 with shaped payload', sm.status === 200 && smd
  && 'balance' in smd && 'lifetime_purchase' in smd && 'spending' in smd
  && 'requests' in smd && 'favorites_count' in smd && 'pending_request' in smd);
report('  stats-male balance.coin_balance = 1000', smd?.balance?.coin_balance === 1000);
report('  stats-male requests.total_sent = 0', smd?.requests?.total_sent === 0);

// ============================================================================
console.log(`\n=== SECTION B — REPORTS ===`);
// ============================================================================

// 5. reports-submit self-report → 400
report('reports-submit rejects self-report (400)',
  (await callFn('reports-submit', { reportedUserId: maleId, reason: 'spam' }, maleJwt)).status === 400);

// 6. reports-submit succeeds
const rep = await callFn('reports-submit',
  { reportedUserId: f2Id, reason: 'harassment', description: 'smoke test' }, maleJwt);
const reportId = rep.body?.data?.reportId;
report('reports-submit succeeds (200) and returns reportId', rep.status === 200 && !!reportId);

// 7. reports-submit spam after 5 → 409
for (let i = 0; i < 4; i++) {
  await callFn('reports-submit', { reportedUserId: f1Id, reason: 'spam', description: `dup ${i}` }, maleJwt);
}
const overlimit = await callFn('reports-submit',
  { reportedUserId: f1Id, reason: 'other', description: 'one too many' }, maleJwt);
report('reports-submit rejects 6th in 24h (409)', overlimit.status === 409);

// 8. reports-admin-review rejects non-admin
report('reports-admin-review rejects non-admin (403)',
  (await callFn('reports-admin-review',
    { reportId, action: 'dismissed', adminNotes: 'no' }, maleJwt)).status === 403);

// 9. reports-admin-review dismissed
const dismiss = await callFn('reports-admin-review',
  { reportId, action: 'dismissed', adminNotes: 'No further action.' }, adminJwt);
report('reports-admin-review dismissed → 200 + status=dismissed',
  dismiss.status === 200 && dismiss.body?.data?.status === 'dismissed');

// 10. warning_issued: new report → review → check notification fired
const rep2 = await callFn('reports-submit',
  { reportedUserId: f2Id, reason: 'harassment', description: 'warn me' }, maleJwt);
// Need a different reporter to bypass the 5/24h cap on the male. Use f1 instead.
const f2ReportByF1 = await callFn('reports-submit',
  { reportedUserId: maleId, reason: 'spam', description: 'female-report-male' }, f1Jwt);
const warnReportId = f2ReportByF1.body?.data?.reportId;
const warn = await callFn('reports-admin-review',
  { reportId: warnReportId, action: 'warning_issued', adminNotes: 'Please be respectful.' }, adminJwt);
report('reports-admin-review warning_issued → 200 + status=action_taken',
  warn.status === 200 && warn.body?.data?.status === 'action_taken');

// Check that an account_warning notification was created for the male
const warnNotif = await rest(
  `/rest/v1/notifications?recipient_id=eq.${maleId}&type=eq.account_warning&select=title,body`,
  null, 'GET');
report('  account_warning notification fired',
  warnNotif.body?.length === 1 && warnNotif.body[0].body === 'Please be respectful.');

// 11. account_suspended: report f1 by male, admin suspends f1
// Wait — male hit the 5-cap. Use service-role insert to set up the report.
const seedReport = await rest('/rest/v1/reports', {
  reporter_id: maleId, reported_id: f1Id, reason: 'fraud_scam',
  description: 'smoke: setup for suspension', status: 'submitted',
}, 'POST');
const suspendReportId = seedReport.body?.[0]?.id;
const suspend = await callFn('reports-admin-review',
  { reportId: suspendReportId, action: 'account_suspended', adminNotes: 'Account suspended for fraud.' }, adminJwt);
report('reports-admin-review account_suspended → 200 + reportedUserSuspended=true',
  suspend.status === 200 && suspend.body?.data?.reportedUserSuspended === true);

// Verify is_suspended flipped
const f1Check = await rest(`/rest/v1/users?id=eq.${f1Id}&select=is_suspended`, null, 'GET');
report('  users.is_suspended = TRUE for f1', f1Check.body?.[0]?.is_suspended === true);

// account_suspended notification fired
const susNotif = await rest(
  `/rest/v1/notifications?recipient_id=eq.${f1Id}&type=eq.account_suspended&select=title`,
  null, 'GET');
report('  account_suspended notification fired', susNotif.body?.length === 1);

// ============================================================================
console.log(`\n=== SECTION C — BLOCKS ===`);
// ============================================================================

// Restore f1 (un-suspend) so we can test blocks against her cleanly.
await rest(`/rest/v1/users?id=eq.${f1Id}`, { is_suspended: false }, 'PATCH');

// 12. users-block self → 400
report('users-block rejects self (400)',
  (await callFn('users-block', { blockedUserId: maleId }, maleJwt)).status === 400);

// 13. happy block + idempotent re-block
const b1 = await callFn('users-block',
  { blockedUserId: f2Id, reason: 'smoke: block f2' }, maleJwt);
report('users-block succeeds (200)', b1.status === 200 && b1.body?.data?.blocked === true);

const b2 = await callFn('users-block', { blockedUserId: f2Id }, maleJwt);
report('users-block idempotent on 2nd call (200)', b2.status === 200);

// 14. browse view (service-role read): with male's JWT-equivalent context, f2 should be hidden.
// Use REST with male's JWT so RLS sees auth.uid()=male.
const browseMale = await rest(
  `/rest/v1/females_available_view?female_id=in.(${f1Id},${f2Id})&select=female_id`,
  null, 'GET', maleJwt);
const browseMaleIds = (browseMale.body ?? []).map((r) => r.female_id);
report('browse view excludes blocked female (f2)',
  browseMaleIds.includes(f1Id) && !browseMaleIds.includes(f2Id),
  `saw=[${browseMaleIds.join(',')}]`);

// 15. chat-requests-send to blocked female → 403 generic
const sendBlocked = await callFn('chat-requests-send', { femaleId: f2Id }, maleJwt);
report('chat-requests-send to blocked female → 403 generic',
  sendBlocked.status === 403
    && sendBlocked.body?.error?.message === 'Cannot send chat request to this user.');

// 16. reverse-direction block: f1 blocks male; male's view of f1 disappears; send blocked too.
await callFn('users-block', { blockedUserId: maleId, reason: 'reverse' }, f1Jwt);

const browseMaleAfter = await rest(
  `/rest/v1/females_available_view?female_id=in.(${f1Id},${f2Id})&select=female_id`,
  null, 'GET', maleJwt);
const browseMaleAfterIds = (browseMaleAfter.body ?? []).map((r) => r.female_id);
report('browse view excludes female who blocked the caller (reverse direction)',
  !browseMaleAfterIds.includes(f1Id),
  `saw=[${browseMaleAfterIds.join(',')}]`);

const sendBlockedReverse = await callFn('chat-requests-send', { femaleId: f1Id }, maleJwt);
report('chat-requests-send blocked in reverse direction → 403',
  sendBlockedReverse.status === 403);

// 17. unblock + verify send works
await callFn('users-unblock', { blockedUserId: f2Id }, maleJwt);
await callFn('users-unblock', { blockedUserId: maleId }, f1Jwt);

const sendAfterUnblock = await callFn('chat-requests-send', { femaleId: f1Id }, maleJwt);
report('chat-requests-send works after both unblocks',
  sendAfterUnblock.status === 200);

// 18. unblock idempotent
const unb = await callFn('users-unblock', { blockedUserId: f2Id }, maleJwt);
report('users-unblock idempotent on already-unblocked user', unb.status === 200);

console.log(`\n=== Result: ${passes} pass, ${fails} fail ===`);
process.exit(fails === 0 ? 0 : 1);
