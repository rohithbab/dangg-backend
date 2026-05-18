-- =============================================================================
-- pgTAP tests — payouts domain
--
-- Plan covers:
--   * Table shape (columns_are)
--   * CHECK constraints — completed-without-utr, failed-without-reason,
--     non-positive amount, commission >= 100, refunded-without-refund-id
--   * Partial UNIQUE — one active payout per female
--   * RLS — female-own SELECT, admin SELECT-all (via is_admin())
--   * Notification-type enum carries the new payout values
--   * Female can have multiple TERMINAL payouts but only one ACTIVE
--
-- Whole plan runs in one transaction that rolls back at the end.
-- =============================================================================
BEGIN;
SELECT plan(14);

-- ---------------------------------------------------------------------------
-- Setup — 2 females + 1 male (male is irrelevant here but the trigger needs
-- the user_metadata.role and end-user enum only allows female/male).
-- ---------------------------------------------------------------------------
INSERT INTO auth.users (
  instance_id, id, aud, role, email,
  encrypted_password, email_confirmed_at, phone, phone_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
VALUES
  ('00000000-0000-0000-0000-000000000000',
   '80808080-8080-8080-8080-808080808080',
   'authenticated', 'authenticated', NULL, '', NULL, '+919000000080', NOW(),
   '{"provider":"phone","providers":["phone"]}'::jsonb,
   '{"name":"Payout Female A","age":25,"role":"female"}'::jsonb,
   NOW(), NOW()),
  ('00000000-0000-0000-0000-000000000000',
   '81818181-8181-8181-8181-818181818181',
   'authenticated', 'authenticated', NULL, '', NULL, '+919000000081', NOW(),
   '{"provider":"phone","providers":["phone"]}'::jsonb,
   '{"name":"Payout Female B","age":27,"role":"female"}'::jsonb,
   NOW(), NOW());

-- Fund Female A with earnings via the canonical mutator so balance + ledger
-- stay consistent.
SELECT public.credit_female_earnings(
  '80808080-8080-8080-8080-808080808080'::uuid,
  500,
  'chat_earning'::public.earning_transaction_type,
  NULL,
  'Test: fund payout A'
);

-- ---------------------------------------------------------------------------
-- TEST 1 — Table shape — column allowlist.
-- ---------------------------------------------------------------------------
SELECT columns_are(
  'public', 'payouts',
  ARRAY[
    'id', 'female_id',
    'coins_requested', 'coin_value_paisa_snapshot', 'commission_pct_snapshot',
    'payout_amount_paisa', 'payout_method_snapshot',
    'status',
    'requested_at', 'approved_at', 'completed_at', 'failed_at',
    'rejected_at', 'cancelled_at',
    'approved_by', 'completed_by', 'failed_by', 'rejected_by',
    'rejection_reason', 'failure_reason', 'admin_notes', 'utr_number',
    'escrow_earning_id', 'refund_earning_id',
    'created_at', 'updated_at'
  ],
  'payouts exposes the expected column set'
);

-- ---------------------------------------------------------------------------
-- TEST 2 — coins_requested > 0 CHECK rejects zero.
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$INSERT INTO public.payouts
      (female_id, coins_requested, coin_value_paisa_snapshot,
       commission_pct_snapshot, payout_amount_paisa, payout_method_snapshot,
       escrow_earning_id)
    VALUES
      ('80808080-8080-8080-8080-808080808080',
       0, 100, 30.00, 7000, '{}'::jsonb, uuid_generate_v4())$$,
  '23514', NULL,
  'CHECK coins_requested > 0 rejects zero'
);

-- ---------------------------------------------------------------------------
-- TEST 3 — payout_amount_paisa > 0 CHECK rejects zero.
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$INSERT INTO public.payouts
      (female_id, coins_requested, coin_value_paisa_snapshot,
       commission_pct_snapshot, payout_amount_paisa, payout_method_snapshot,
       escrow_earning_id)
    VALUES
      ('80808080-8080-8080-8080-808080808080',
       100, 100, 30.00, 0, '{}'::jsonb, uuid_generate_v4())$$,
  '23514', NULL,
  'CHECK payout_amount_paisa > 0 rejects zero'
);

-- ---------------------------------------------------------------------------
-- TEST 4 — commission_pct_snapshot < 100 CHECK rejects 100.
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$INSERT INTO public.payouts
      (female_id, coins_requested, coin_value_paisa_snapshot,
       commission_pct_snapshot, payout_amount_paisa, payout_method_snapshot,
       escrow_earning_id)
    VALUES
      ('80808080-8080-8080-8080-808080808080',
       100, 100, 100.00, 1, '{}'::jsonb, uuid_generate_v4())$$,
  '23514', NULL,
  'CHECK commission_pct_snapshot < 100 rejects 100'
);

-- ---------------------------------------------------------------------------
-- TEST 5 — escrow_earning_id is NOT NULL.
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$INSERT INTO public.payouts
      (female_id, coins_requested, coin_value_paisa_snapshot,
       commission_pct_snapshot, payout_amount_paisa, payout_method_snapshot)
    VALUES
      ('80808080-8080-8080-8080-808080808080',
       100, 100, 30.00, 7000, '{}'::jsonb)$$,
  '23502', NULL,
  'escrow_earning_id NOT NULL is enforced'
);

-- Insert a valid pending row for the remaining tests.
INSERT INTO public.payouts
  (id, female_id, coins_requested, coin_value_paisa_snapshot,
   commission_pct_snapshot, payout_amount_paisa, payout_method_snapshot,
   escrow_earning_id)
VALUES
  ('a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1',
   '80808080-8080-8080-8080-808080808080',
   100, 100, 30.00, 7000,
   jsonb_build_object('method','upi','upi_id','test@oksbi'),
   uuid_generate_v4());

-- ---------------------------------------------------------------------------
-- TEST 6 — Partial UNIQUE: a second active payout for the same female is
--           rejected (one pending already exists).
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$INSERT INTO public.payouts
      (female_id, coins_requested, coin_value_paisa_snapshot,
       commission_pct_snapshot, payout_amount_paisa, payout_method_snapshot,
       escrow_earning_id)
    VALUES
      ('80808080-8080-8080-8080-808080808080',
       50, 100, 30.00, 3500, '{}'::jsonb, uuid_generate_v4())$$,
  '23505', NULL,
  'Partial UNIQUE payouts_one_active_per_female_idx blocks a 2nd active payout'
);

-- ---------------------------------------------------------------------------
-- TEST 7 — CHECK payouts_completed_has_utr: completed without UTR rejected.
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$UPDATE public.payouts
       SET status = 'completed',
           completed_at = NOW(),
           completed_by = '80808080-8080-8080-8080-808080808080',
           approved_at = NOW(),
           approved_by = '80808080-8080-8080-8080-808080808080'
     WHERE id = 'a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1'$$,
  '23514', NULL,
  'CHECK completed_has_utr blocks status=completed without utr_number'
);

-- ---------------------------------------------------------------------------
-- TEST 8 — CHECK payouts_failed_has_reason: failed without reason rejected.
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$UPDATE public.payouts
       SET status = 'failed',
           failed_at = NOW(),
           failed_by = '80808080-8080-8080-8080-808080808080',
           approved_at = NOW(),
           approved_by = '80808080-8080-8080-8080-808080808080',
           refund_earning_id = uuid_generate_v4()
     WHERE id = 'a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1'$$,
  '23514', NULL,
  'CHECK failed_has_reason blocks status=failed without failure_reason'
);

-- ---------------------------------------------------------------------------
-- TEST 9 — CHECK payouts_refunded_has_refund_earning: rejected without
--           refund_earning_id is blocked.
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$UPDATE public.payouts
       SET status = 'rejected',
           rejected_at = NOW(),
           rejected_by = '80808080-8080-8080-8080-808080808080',
           rejection_reason = 'no refund_earning_id'
     WHERE id = 'a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1'$$,
  '23514', NULL,
  'CHECK refunded_has_refund_earning blocks rejected with NULL refund_earning_id'
);

-- ---------------------------------------------------------------------------
-- TEST 10 — RLS female-own SELECT: Female A sees her own; Female B sees zero.
-- ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub":"80808080-8080-8080-8080-808080808080","role":"authenticated"}';

SELECT is(
  (SELECT COUNT(*)::int FROM public.payouts WHERE female_id = '80808080-8080-8080-8080-808080808080'),
  1,
  'Female A sees her own payout under RLS'
);

SET LOCAL "request.jwt.claims" TO '{"sub":"81818181-8181-8181-8181-818181818181","role":"authenticated"}';

SELECT is(
  (SELECT COUNT(*)::int FROM public.payouts),
  0,
  'Female B sees zero payouts (not addressed to her)'
);

-- ---------------------------------------------------------------------------
-- TEST 11 — RLS admin SELECT-all: a JWT carrying user_metadata.role=admin
--           sees ALL payouts via the is_admin() helper.
-- ---------------------------------------------------------------------------
SET LOCAL "request.jwt.claims" TO
  '{"sub":"99999999-9999-9999-9999-999999999999","role":"authenticated","user_metadata":{"role":"admin"}}';

SELECT is(
  (SELECT COUNT(*)::int FROM public.payouts),
  1,
  'Admin (via JWT user_metadata.role=admin) sees all payouts'
);

-- ---------------------------------------------------------------------------
-- TEST 12 — notification_type enum carries the four new payout slots
--           (payout_processed and payout_rejected already existed; we re-use
--           payout_processed for "completed").
-- ---------------------------------------------------------------------------
RESET ROLE;

SELECT is(
  (SELECT array_agg(enumlabel ORDER BY enumlabel)
     FROM pg_enum
    WHERE enumtypid = (SELECT oid FROM pg_type WHERE typname = 'notification_type')
      AND enumlabel IN (
        'payout_requested', 'payout_approved', 'payout_processed',
        'payout_rejected', 'payout_failed', 'payout_cancelled'
      )),
  ARRAY[
    'payout_approved', 'payout_cancelled', 'payout_failed',
    'payout_processed', 'payout_rejected', 'payout_requested'
  ]::name[],
  'notification_type enum contains all 6 payout slots'
);

-- ---------------------------------------------------------------------------
-- TEST 13 — Multiple TERMINAL payouts coexist for the same female; the
--           partial UNIQUE only constrains active (pending/approved).
--           Transition the existing payout to a terminal state, then prove
--           a NEW pending payout can be inserted.
-- ---------------------------------------------------------------------------
UPDATE public.payouts
   SET status = 'cancelled',
       cancelled_at = NOW(),
       refund_earning_id = uuid_generate_v4()
 WHERE id = 'a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1';

SELECT lives_ok(
  $$INSERT INTO public.payouts
      (female_id, coins_requested, coin_value_paisa_snapshot,
       commission_pct_snapshot, payout_amount_paisa, payout_method_snapshot,
       escrow_earning_id)
    VALUES
      ('80808080-8080-8080-8080-808080808080',
       50, 100, 30.00, 3500,
       jsonb_build_object('method','upi','upi_id','test@oksbi'),
       uuid_generate_v4())$$,
  'After cancellation, Female A can request a fresh payout (partial UNIQUE only constrains active rows)'
);

SELECT * FROM finish();
ROLLBACK;
