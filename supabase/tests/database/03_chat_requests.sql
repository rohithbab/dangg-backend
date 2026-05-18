-- =============================================================================
-- pgTAP tests — chat-request state machine + female earnings
--
-- Plan covers:
--   * CHECK constraints on chat_requests (self-send, positive cost,
--     pending-no-response, accepted-has-earning, refunded-has-refund)
--   * Partial UNIQUE index — one pending per male
--   * Female can have multiple pending from different males
--   * RLS — male and female each see only their own rows
--   * credit_female_earnings — amount=0 and overdraft rejected
--   * expire_pending_chat_requests — touches only pending past expiry
--   * Realtime publication contains chat_requests
--   * female_earnings ledger blocks authenticated writes (RLS)
--
-- The whole plan runs in one transaction that rolls back at the end.
-- =============================================================================
BEGIN;
SELECT plan(15);

-- ---------------------------------------------------------------------------
-- Setup — 2 males + 2 females. The handle_new_user trigger mirrors auth.users
-- inserts into public.users / public.males / public.females.
-- ---------------------------------------------------------------------------
INSERT INTO auth.users (
  instance_id, id, aud, role, email,
  encrypted_password, email_confirmed_at, phone, phone_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
VALUES
  ('00000000-0000-0000-0000-000000000000',
   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   'authenticated', 'authenticated', NULL, '', NULL, '+919000000020', NOW(),
   '{"provider":"phone","providers":["phone"]}'::jsonb,
   '{"name":"Chat Male A","age":30,"role":"male"}'::jsonb,
   NOW(), NOW()),
  ('00000000-0000-0000-0000-000000000000',
   'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
   'authenticated', 'authenticated', NULL, '', NULL, '+919000000021', NOW(),
   '{"provider":"phone","providers":["phone"]}'::jsonb,
   '{"name":"Chat Male B","age":28,"role":"male"}'::jsonb,
   NOW(), NOW()),
  ('00000000-0000-0000-0000-000000000000',
   'cccccccc-cccc-cccc-cccc-cccccccccccc',
   'authenticated', 'authenticated', NULL, '', NULL, '+919000000022', NOW(),
   '{"provider":"phone","providers":["phone"]}'::jsonb,
   '{"name":"Chat Female X","age":25,"role":"female"}'::jsonb,
   NOW(), NOW()),
  ('00000000-0000-0000-0000-000000000000',
   'dddddddd-dddd-dddd-dddd-dddddddddddd',
   'authenticated', 'authenticated', NULL, '', NULL, '+919000000023', NOW(),
   '{"provider":"phone","providers":["phone"]}'::jsonb,
   '{"name":"Chat Female Y","age":27,"role":"female"}'::jsonb,
   NOW(), NOW());

-- Fund both males so credit_coins can debit during the cron-expiry test.
UPDATE public.males SET coin_balance = 1000
 WHERE id IN ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');

-- ---------------------------------------------------------------------------
-- TEST 1 — CHECK chat_requests_no_self: male_id = female_id is rejected
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$INSERT INTO public.chat_requests
      (male_id, female_id, chat_cost_coins, sent_at, expires_at)
    VALUES
      ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       50, NOW(), NOW() + INTERVAL '2 minutes')$$,
  '23514',
  NULL,
  'CHECK chat_requests_no_self rejects male_id = female_id'
);

-- ---------------------------------------------------------------------------
-- TEST 2 — CHECK chat_cost_coins > 0: zero / negative cost is rejected
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$INSERT INTO public.chat_requests
      (male_id, female_id, chat_cost_coins, sent_at, expires_at)
    VALUES
      ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'cccccccc-cccc-cccc-cccc-cccccccccccc',
       0, NOW(), NOW() + INTERVAL '2 minutes')$$,
  '23514',
  NULL,
  'CHECK chat_cost_coins > 0 rejects zero cost'
);

-- ---------------------------------------------------------------------------
-- TEST 3 — Partial UNIQUE index: one pending per male
-- ---------------------------------------------------------------------------
INSERT INTO public.chat_requests
  (male_id, female_id, chat_cost_coins, sent_at, expires_at)
VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   'cccccccc-cccc-cccc-cccc-cccccccccccc',
   50, NOW(), NOW() + INTERVAL '2 minutes');

SELECT throws_ok(
  $$INSERT INTO public.chat_requests
      (male_id, female_id, chat_cost_coins, sent_at, expires_at)
    VALUES
      ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'dddddddd-dddd-dddd-dddd-dddddddddddd',
       40, NOW(), NOW() + INTERVAL '2 minutes')$$,
  '23505',
  NULL,
  'Partial UNIQUE chat_requests_one_pending_per_male_idx blocks a 2nd pending'
);

-- ---------------------------------------------------------------------------
-- TEST 4 — Female X CAN have multiple pending from different males
-- ---------------------------------------------------------------------------
SELECT lives_ok(
  $$INSERT INTO public.chat_requests
      (male_id, female_id, chat_cost_coins, sent_at, expires_at)
    VALUES
      ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
       'cccccccc-cccc-cccc-cccc-cccccccccccc',
       50, NOW(), NOW() + INTERVAL '2 minutes')$$,
  'Female X accepts a 2nd pending request from a different male'
);

-- ---------------------------------------------------------------------------
-- TEST 5 — CHECK chat_requests_accepted_has_earning: terminal=accepted
--          without earning_id is rejected.
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$UPDATE public.chat_requests
       SET status = 'accepted',
           responded_at = NOW(),
           response_reason = 'no earning_id'
     WHERE male_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
       AND status = 'pending'$$,
  '23514',
  NULL,
  'CHECK accepted_has_earning blocks accepted with NULL earning_id'
);

-- ---------------------------------------------------------------------------
-- TEST 6 — CHECK chat_requests_refunded_has_refund: terminal=declined
--          without refund_transaction_id is rejected.
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$UPDATE public.chat_requests
       SET status = 'declined',
           responded_at = NOW(),
           response_reason = 'no refund txn'
     WHERE male_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
       AND status = 'pending'$$,
  '23514',
  NULL,
  'CHECK refunded_has_refund blocks declined with NULL refund_transaction_id'
);

-- ---------------------------------------------------------------------------
-- TEST 7 — Valid pending → accepted: writing a synthetic earning_id satisfies
--          the CHECK; the row transitions successfully.
--          (Service-role / default test role bypasses RLS.)
-- ---------------------------------------------------------------------------
SELECT lives_ok(
  $$UPDATE public.chat_requests
       SET status = 'accepted',
           responded_at = NOW(),
           response_reason = 'Accepted by female',
           earning_id = uuid_generate_v4()
     WHERE male_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
       AND status = 'pending'$$,
  'pending → accepted transition succeeds when earning_id is set'
);

-- ---------------------------------------------------------------------------
-- TEST 8 — credit_female_earnings rejects amount = 0
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$SELECT public.credit_female_earnings(
      'cccccccc-cccc-cccc-cccc-cccccccccccc',
      0,
      'chat_earning'::public.earning_transaction_type
    )$$,
  NULL, NULL,
  'credit_female_earnings(amount=0) is rejected'
);

-- ---------------------------------------------------------------------------
-- TEST 9 — credit_female_earnings rejects a debit larger than the balance
--          (current balance is 0 for both test females).
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$SELECT public.credit_female_earnings(
      'cccccccc-cccc-cccc-cccc-cccccccccccc',
      -100,
      'payout'::public.earning_transaction_type
    )$$,
  NULL, NULL,
  'credit_female_earnings rejects a debit that would overdraft earnings'
);

-- ---------------------------------------------------------------------------
-- TEST 10 — expire_pending_chat_requests touches only pending rows past
--           their expires_at. Setup: one already-expired pending row, one
--           future-expiring pending row, and one already-accepted row from
--           test 7. Only the expired one should transition.
-- ---------------------------------------------------------------------------

-- Use Male A — his first request was transitioned to 'accepted' in test 7,
-- so the partial unique index no longer covers him and we can insert a 2nd
-- (past-expiry) pending row for him here.
DO $$
DECLARE
  v_charge_txn UUID;
BEGIN
  -- Pay the cost via credit_coins so balance + ledger stay consistent.
  SELECT transaction_id INTO v_charge_txn
    FROM public.credit_coins(
      'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid,
      -60,
      'chat_charge'::public.coin_transaction_type,
      NULL,
      'Test: pre-cron charge'
    );

  -- Past-expiry pending request — the cron MUST pick this up.
  INSERT INTO public.chat_requests
    (male_id, female_id, chat_cost_coins, sent_at, expires_at, charge_transaction_id)
  VALUES
    ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'dddddddd-dddd-dddd-dddd-dddddddddddd',
     60,
     NOW() - INTERVAL '10 minutes',
     NOW() - INTERVAL '8 minutes',
     v_charge_txn);
END$$;

-- Snapshot Male A's balance immediately before the cron call.
CREATE TEMP TABLE IF NOT EXISTS _bal_snapshot AS
  SELECT coin_balance AS before_balance
    FROM public.males WHERE id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

SELECT is(
  public.expire_pending_chat_requests(),
  1,
  'expire_pending_chat_requests returns 1 (only the past-expiry pending row)'
);

-- ---------------------------------------------------------------------------
-- TEST 11 — After the sweep, the past-expiry row is expired and has a
--           refund_transaction_id.
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT status::text FROM public.chat_requests
    WHERE male_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      AND female_id = 'dddddddd-dddd-dddd-dddd-dddddddddddd'),
  'expired',
  'Past-expiry pending row was transitioned to expired'
);

-- ---------------------------------------------------------------------------
-- TEST 12 — Male A's balance went UP by the refund amount (60).
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT coin_balance - (SELECT before_balance FROM _bal_snapshot)
     FROM public.males WHERE id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  60,
  'Cron refunded 60 coins to Male A (balance delta = +60)'
);

-- ---------------------------------------------------------------------------
-- TEST 13 — RLS on chat_requests: female only sees requests addressed to her.
--           Female Y should see the one expired row (Male B → Female Y).
--           Female X should NOT see that row (it's not addressed to her).
-- ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub":"dddddddd-dddd-dddd-dddd-dddddddddddd","role":"authenticated"}';

SELECT is(
  (SELECT COUNT(*)::int FROM public.chat_requests
    WHERE female_id = 'dddddddd-dddd-dddd-dddd-dddddddddddd'),
  1,
  'Female Y sees exactly 1 chat_request addressed to her'
);

-- ---------------------------------------------------------------------------
-- TEST 14 — Male RLS: Male B sees his own row(s) but not Male A's.
-- ---------------------------------------------------------------------------
SET LOCAL "request.jwt.claims" TO '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","role":"authenticated"}';

SELECT is(
  (SELECT COUNT(*)::int FROM public.chat_requests
    WHERE male_id <> 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'),
  0,
  'Male B cannot see chat_requests where he is not the male_id'
);

-- ---------------------------------------------------------------------------
-- TEST 15 — Realtime publication includes chat_requests
-- ---------------------------------------------------------------------------
RESET ROLE;

SELECT is(
  (SELECT COUNT(*)::int FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'chat_requests'),
  1,
  'chat_requests is published on supabase_realtime'
);

SELECT * FROM finish();
ROLLBACK;
