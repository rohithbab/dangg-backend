-- =============================================================================
-- pgTAP tests — payments domain invariants
--
-- Plan covers:
--   * credit_coins atomicity / sign rules / negative-balance guard / amount=0 guard
--   * payments / coin_transactions RLS — male sees own only
--   * coin_packages RLS — only active rows visible to authenticated
--   * webhook_events UNIQUE constraint enforces idempotency
--   * credit_coins is NOT callable from authenticated role
-- =============================================================================

BEGIN;
SELECT plan(15);

-- ---------------------------------------------------------------------------
-- Setup — 1 male + 1 female. The auth.users insert fires our trigger which
-- creates the public.users + males / females rows.
-- ---------------------------------------------------------------------------
INSERT INTO auth.users (
  instance_id, id, aud, role, email,
  encrypted_password, email_confirmed_at, phone, phone_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
VALUES
  ('00000000-0000-0000-0000-000000000000',
   '55555555-5555-5555-5555-555555555555',
   'authenticated', 'authenticated', NULL, '', NULL, '+919000000010', NOW(),
   '{"provider":"phone","providers":["phone"]}'::jsonb,
   '{"name":"Pay Male","age":30,"role":"male"}'::jsonb,
   NOW(), NOW()),
  ('00000000-0000-0000-0000-000000000000',
   '66666666-6666-6666-6666-666666666666',
   'authenticated', 'authenticated', NULL, '', NULL, '+919000000011', NOW(),
   '{"provider":"phone","providers":["phone"]}'::jsonb,
   '{"name":"Pay Male 2","age":28,"role":"male"}'::jsonb,
   NOW(), NOW());

-- ---------------------------------------------------------------------------
-- TEST 1 — credit_coins credits and inserts a ledger row
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT new_balance FROM public.credit_coins(
    '55555555-5555-5555-5555-555555555555',
    100,
    'purchase'::coin_transaction_type,
    NULL,
    'Test credit'
  )),
  100,
  'credit_coins(+100) returns new_balance=100'
);

SELECT is(
  (SELECT coin_balance FROM public.males WHERE id = '55555555-5555-5555-5555-555555555555'),
  100,
  'males.coin_balance was updated to 100'
);

SELECT is(
  (SELECT COUNT(*)::int FROM public.coin_transactions WHERE male_id = '55555555-5555-5555-5555-555555555555'),
  1,
  'one ledger row exists after the credit'
);

SELECT is(
  (SELECT balance_after FROM public.coin_transactions WHERE male_id = '55555555-5555-5555-5555-555555555555' ORDER BY created_at DESC LIMIT 1),
  100,
  'ledger row records balance_after = 100'
);

-- ---------------------------------------------------------------------------
-- TEST 5 — credit_coins debits when amount is negative
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT new_balance FROM public.credit_coins(
    '55555555-5555-5555-5555-555555555555', -30, 'chat_charge'::coin_transaction_type
  )),
  70,
  'credit_coins(-30) brings balance to 70'
);

-- ---------------------------------------------------------------------------
-- TEST 6 — credit_coins rejects amount = 0
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$SELECT credit_coins(
      '55555555-5555-5555-5555-555555555555', 0, 'purchase'::coin_transaction_type
    )$$,
  NULL, NULL,
  'credit_coins with amount=0 throws'
);

-- ---------------------------------------------------------------------------
-- TEST 7 — credit_coins rejects when new balance would go negative
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$SELECT credit_coins(
      '55555555-5555-5555-5555-555555555555', -1000, 'chat_charge'::coin_transaction_type
    )$$,
  NULL, NULL,
  'credit_coins rejects a debit that would overdraft the balance'
);

-- ---------------------------------------------------------------------------
-- TEST 8 — credit_coins rejects an unknown male id
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$SELECT credit_coins(
      '99999999-9999-9999-9999-999999999999', 50, 'purchase'::coin_transaction_type
    )$$,
  NULL, NULL,
  'credit_coins throws when the male id does not exist'
);

-- ---------------------------------------------------------------------------
-- TEST 9 — coin_packages: authenticated sees only active rows (seed has 6)
-- ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub":"55555555-5555-5555-5555-555555555555","role":"authenticated"}';

SELECT is(
  (SELECT COUNT(*)::int FROM public.coin_packages),
  6,
  'authenticated sees 6 active coin packages'
);

-- ---------------------------------------------------------------------------
-- TEST 10-11 — coin_transactions RLS: male sees own only
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT COUNT(*)::int FROM public.coin_transactions),
  2,
  'Male 1 sees only his 2 ledger rows (credit + debit)'
);

SET LOCAL "request.jwt.claims" TO '{"sub":"66666666-6666-6666-6666-666666666666","role":"authenticated"}';

SELECT is(
  (SELECT COUNT(*)::int FROM public.coin_transactions),
  0,
  'Male 2 sees zero ledger rows (no entries for him)'
);

-- ---------------------------------------------------------------------------
-- TEST 12 — payments RLS: male sees own only
-- ---------------------------------------------------------------------------
RESET ROLE;
INSERT INTO public.payments (male_id, package_id, razorpay_order_id, amount_paisa, coins_to_credit)
VALUES (
  '55555555-5555-5555-5555-555555555555',
  (SELECT id FROM public.coin_packages WHERE name = 'Standard'),
  'order_test_001',
  50000,
  575
);

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub":"66666666-6666-6666-6666-666666666666","role":"authenticated"}';

SELECT is(
  (SELECT COUNT(*)::int FROM public.payments),
  0,
  'Male 2 cannot see Male 1''s payment row'
);

SET LOCAL "request.jwt.claims" TO '{"sub":"55555555-5555-5555-5555-555555555555","role":"authenticated"}';

SELECT is(
  (SELECT COUNT(*)::int FROM public.payments),
  1,
  'Male 1 can see his own payment row'
);

-- ---------------------------------------------------------------------------
-- TEST 14 — authenticated role cannot call credit_coins directly
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$SELECT credit_coins(
      '55555555-5555-5555-5555-555555555555', 100, 'purchase'::coin_transaction_type
    )$$,
  '42501',
  NULL,
  'authenticated role cannot EXECUTE credit_coins directly'
);

-- ---------------------------------------------------------------------------
-- TEST 15 — webhook_events UNIQUE(provider, event_id) enforces idempotency
-- ---------------------------------------------------------------------------
RESET ROLE;
INSERT INTO public.webhook_events (provider, event_id, event_type, payload)
VALUES ('razorpay', 'payment.captured::pay_xxx', 'payment.captured', '{}'::jsonb);

SELECT throws_ok(
  $$INSERT INTO public.webhook_events (provider, event_id, event_type, payload)
    VALUES ('razorpay', 'payment.captured::pay_xxx', 'payment.captured', '{}'::jsonb)$$,
  '23505',
  NULL,
  'webhook_events UNIQUE rejects a duplicate (provider, event_id)'
);

SELECT * FROM finish();
ROLLBACK;
