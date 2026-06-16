// End-to-end flow test — mirrors dangg-frontend/mobile_app_screen_spec.md.
// Walks the real user journey against a running stack, using the SAME endpoints
// the app calls at each screen. Auth uses real signInWithOtp → verifyOtp (test
// OTP numbers), then the marketplace loop (browse → request → accept → payout).
//
//   Required env: SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY (keys are NOT
//   hardcoded — they're secrets). Optional: SUPABASE_API_URL.
const API = process.env.SUPABASE_API_URL ?? 'http://localhost:8000';
const ANON = process.env.SUPABASE_ANON_KEY;
const SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!ANON || !SERVICE) {
  console.error('Set SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY (optionally SUPABASE_API_URL).');
  process.exit(1);
}

const TEST_CODE = '123456';
const FEMALE = { phone: '+919000000201', meta: { name: 'E2E Female', age: 24, role: 'female' } };
const MALE = { phone: '+919000000301', meta: { name: 'E2E Male', age: 27, role: 'male' } };

let pass = 0, fail = 0;
const fails = [];
function step(screen, label, ok, detail = '') {
  ok ? pass++ : fail++;
  if (!ok) fails.push(`[${screen}] ${label}`);
  console.log(`  ${ok ? '✅' : '❌'} [${screen}] ${label}${detail ? '  — ' + detail : ''}`);
}

async function http(path, { method = 'GET', token, body, service = false } = {}) {
  const headers = { apikey: service ? SERVICE : ANON, 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  else if (service) headers.Authorization = `Bearer ${SERVICE}`;
  const r = await fetch(API + path, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const t = await r.text();
  let j; try { j = t ? JSON.parse(t) : null; } catch { j = t; }
  return { status: r.status, body: j };
}
const fn = (name, body, token) => http(`/functions/v1/${name}`, { method: 'POST', token, body });
const rpc = (name, body, token, service = false) =>
  http(`/rest/v1/rpc/${name}`, { method: 'POST', token, body, service });
const data = (r) => r.body?.data ?? r.body;

async function signupViaOtp(u) {
  // signInWithOtp({ phone, options: { data } }) — metadata feeds handle_new_user.
  await http('/auth/v1/otp', { method: 'POST', body: { phone: u.phone, create_user: true, data: u.meta } });
  const v = await http('/auth/v1/verify', { method: 'POST', body: { type: 'sms', phone: u.phone, token: TEST_CODE } });
  return { token: v.body?.access_token, userId: v.body?.user?.id, raw: v };
}

(async () => {
  console.log(`\n=== dangg E2E — full screen flow vs ${API} ===\n`);

  // ───────── SECTION 1 — FEMALE FLOW ─────────
  console.log('SECTION 1 — FEMALE FLOW');
  const fem = await signupViaOtp(FEMALE);
  step('1.1-1.2', 'Female signup via OTP → session', !!fem.token && !!fem.userId, fem.userId);
  const femaleId = fem.userId;

  const femRow = await http(`/rest/v1/females?id=eq.${femaleId}&select=id,verification_status`, { service: true });
  step('1.1', 'handle_new_user provisioned females row', femRow.body?.[0]?.id === femaleId,
    `status=${femRow.body?.[0]?.verification_status}`);

  // UPI method: ONLY upi_id may be set (CHECK payout_details_method_fields).
  await http(`/rest/v1/payout_details?female_id=eq.${femaleId}`, { method: 'DELETE', service: true });
  const bank = await http('/rest/v1/payout_details', { method: 'POST', service: true,
    body: { female_id: femaleId, method: 'upi', upi_id: 'e2e@oksbi', is_admin_verified: true } });
  step('1.3', 'Bank/UPI details saved (payout_details row)', bank.status >= 200 && bank.status < 300, `http ${bank.status}`);

  const sign = await fn('media-sign', { category: 'verification', contentType: 'image/jpeg' }, fem.token);
  step('1.4-1.5', 'Verification photo presigned (media-sign → R2)', !!data(sign)?.uploadUrl);

  const approve = await http(`/rest/v1/females?id=eq.${femaleId}`, { method: 'PATCH', service: true,
    body: { verification_status: 'verified', verification_submitted_at: new Date().toISOString(),
      verification_decided_at: new Date().toISOString() } });
  step('1.6', 'Admin approves verification', approve.status >= 200 && approve.status < 300);

  await http('/auth/v1/user', { method: 'PUT', token: fem.token, body: { password: 'Password123!' } });
  const femLogin = await http('/auth/v1/token?grant_type=password', { method: 'POST',
    body: { phone: FEMALE.phone, password: 'Password123!' } });
  step('1.7-1.10', 'Female phone+password login', !!femLogin.body?.access_token);
  const femToken = femLogin.body?.access_token ?? fem.token;

  const vstatus = await http(`/rest/v1/females?id=eq.${femaleId}&select=verification_status`, { token: femToken });
  step('1.8', 'Verification-status check = verified', vstatus.body?.[0]?.verification_status === 'verified');

  const online = await fn('female-availability-toggle', { isOnline: true }, femToken);
  step('1.14', 'Female toggles ONLINE', data(online)?.isOnline === true);
  const hb = await rpc('female_heartbeat', {}, femToken);
  step('1.14', 'Female presence heartbeat', hb.status >= 200 && hb.status < 300);

  // ───────── SECTION 2 — MALE FLOW ─────────
  console.log('\nSECTION 2 — MALE FLOW');
  const male = await signupViaOtp(MALE);
  step('2.1-2.2', 'Male signup via OTP → session', !!male.token && !!male.userId, male.userId);
  const maleId = male.userId;
  const maleToken = male.token;

  const pkgs = await http('/rest/v1/coin_packages?is_active=eq.true&order=price_paisa.asc&select=id,coins,price_paisa',
    { token: maleToken });
  const pkg = pkgs.body?.[0];
  step('2.x', 'Coin packages listed', Array.isArray(pkgs.body) && pkgs.body.length > 0, `${pkgs.body?.length} pkgs`);

  const order = await fn('payments-create-order', { packageId: pkg?.id }, maleToken);
  const oid = data(order)?.razorpayOrderId;
  step('2.x', 'Razorpay order created (test mode)', !!oid && !String(oid).startsWith('order_mock'), oid);

  const credit = await rpc('credit_coins',
    { p_male_id: maleId, p_amount: 500, p_type: 'purchase', p_reference_id: null, p_description: 'e2e: simulated purchase' },
    null, true);
  step('2.x', 'Coins credited (purchase path)', credit.status >= 200 && credit.status < 300,
    `balance=${credit.body?.[0]?.new_balance}`);

  const browse = await rpc('browse_females', { p_filters: { quick: 'online', onlineOnly: true } }, maleToken);
  step('2.6', 'Male browses → sees online female', JSON.stringify(browse.body).includes(femaleId),
    `${Array.isArray(browse.body) ? browse.body.length : '?'} online`);

  const prof = await http(`/rest/v1/females?id=eq.${femaleId}&select=id,is_online`, { token: maleToken });
  step('2.7', 'Female profile preview', prof.body?.[0]?.id === femaleId);

  // ───────── SECTION 3 — CHAT REQUEST LOOP ─────────
  console.log('\nSECTION 3 — CHAT REQUEST LOOP');
  const sent = await fn('chat-requests-send', { femaleId }, maleToken);
  const cr = data(sent)?.chatRequestId;
  step('2.6/2.7', 'Male sends chat request (coins charged)', sent.status === 200 && !!cr,
    `charged=${data(sent)?.coinsCharged} bal=${data(sent)?.newCoinBalance}`);

  const notif = await http('/rest/v1/notifications?select=type&limit=10', { token: femToken });
  step('1.27/1.28', 'Female receives incoming-request notification',
    Array.isArray(notif.body) && notif.body.length > 0, `${notif.body?.length} notifs`);

  const acc = await fn('chat-requests-respond', { chatRequestId: cr, action: 'accept' }, femToken);
  step('1.28', 'Female accepts → earns + chat session created',
    acc.status === 200 && !!data(acc)?.chatSessionId, `earned=${data(acc)?.newEarningsBalanceCoins}`);

  const earn = await rpc('female_earnings_balance', {}, femToken);
  step('1.15', 'Female earnings dashboard', earn.status >= 200 && earn.status < 300,
    JSON.stringify(earn.body).slice(0, 90));

  await rpc('credit_female_earnings',
    { p_female_id: femaleId, p_amount: 2000, p_type: 'chat_earning', p_reference_id: null, p_description: 'e2e: accrued' },
    null, true);
  const payout = await fn('payouts-request', { coinsToWithdraw: 500 }, femToken);
  step('1.16', 'Female requests payout', payout.status === 200,
    JSON.stringify(data(payout)).slice(0, 110));

  // ───────── summary ─────────
  console.log(`\n=== RESULT: ${pass} passed, ${fail} failed ===`);
  if (fail) { console.log('Failures:'); fails.forEach((f) => console.log('  - ' + f)); process.exit(1); }
})().catch((e) => { console.error('E2E crashed:', e); process.exit(1); });
