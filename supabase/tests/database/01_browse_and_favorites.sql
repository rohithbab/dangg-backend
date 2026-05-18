-- =============================================================================
-- pgTAP tests — browse + favorites privacy invariants
--
-- Run with:
--   supabase test db
--
-- The tests run inside a single transaction that ROLLBACKs at the end —
-- no state is persisted to your local DB. The test plan declares an
-- exact assertion count; mismatches fail the run.
-- =============================================================================

BEGIN;
SELECT plan(20);

-- ---------------------------------------------------------------------------
-- SETUP — insert 4 users as the default test role (postgres / superuser).
-- The `handle_new_user` trigger mirrors them into public.users +
-- public.females / public.males. RLS-targeted blocks below explicitly
-- switch to `authenticated` + a JWT-claim `sub` for each test identity.
-- ---------------------------------------------------------------------------
INSERT INTO auth.users (
  instance_id, id, aud, role, email,
  encrypted_password, email_confirmed_at, phone, phone_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
VALUES
  ('00000000-0000-0000-0000-000000000000',
   '11111111-1111-1111-1111-111111111111',
   'authenticated', 'authenticated', NULL, '', NULL, '+919000000001', NOW(),
   '{"provider":"phone","providers":["phone"]}'::jsonb,
   '{"name":"Test Female 1","age":25,"role":"female"}'::jsonb,
   NOW(), NOW()),
  ('00000000-0000-0000-0000-000000000000',
   '22222222-2222-2222-2222-222222222222',
   'authenticated', 'authenticated', NULL, '', NULL, '+919000000002', NOW(),
   '{"provider":"phone","providers":["phone"]}'::jsonb,
   '{"name":"Test Female 2","age":28,"role":"female"}'::jsonb,
   NOW(), NOW()),
  ('00000000-0000-0000-0000-000000000000',
   '33333333-3333-3333-3333-333333333333',
   'authenticated', 'authenticated', NULL, '', NULL, '+919000000003', NOW(),
   '{"provider":"phone","providers":["phone"]}'::jsonb,
   '{"name":"Test Male 1","age":30,"role":"male"}'::jsonb,
   NOW(), NOW()),
  ('00000000-0000-0000-0000-000000000000',
   '44444444-4444-4444-4444-444444444444',
   'authenticated', 'authenticated', NULL, '', NULL, '+919000000004', NOW(),
   '{"provider":"phone","providers":["phone"]}'::jsonb,
   '{"name":"Test Male 2","age":32,"role":"male"}'::jsonb,
   NOW(), NOW());

-- Verify the trigger mirrored every auth row into public.users.
SELECT is(
  (SELECT COUNT(*) FROM public.users WHERE id IN (
    '11111111-1111-1111-1111-111111111111',
    '22222222-2222-2222-2222-222222222222',
    '33333333-3333-3333-3333-333333333333',
    '44444444-4444-4444-4444-444444444444'
  )),
  4::bigint,
  'Auth trigger created 4 public.users rows'
);

-- The trigger pre-creates the role-specific rows with default values —
-- UPDATE them into the shapes the tests require (one verified, one pending).
UPDATE public.females
SET verification_status = 'verified', is_online = TRUE, coin_price = 50
WHERE id = '11111111-1111-1111-1111-111111111111';

UPDATE public.females
SET verification_status = 'pending', is_online = FALSE, coin_price = 50
WHERE id = '22222222-2222-2222-2222-222222222222';

UPDATE public.males
SET coin_balance = 1000
WHERE id = '33333333-3333-3333-3333-333333333333';

UPDATE public.males
SET coin_balance = 500
WHERE id = '44444444-4444-4444-4444-444444444444';

-- Payout details only for the verified female.
INSERT INTO public.payout_details (female_id, method, upi_id)
VALUES ('11111111-1111-1111-1111-111111111111', 'upi', 'female1@oksbi');

-- ---------------------------------------------------------------------------
-- TEST 2-4 — females_available_view column allowlist
-- ---------------------------------------------------------------------------
SELECT columns_are(
  'public', 'females_available_view',
  ARRAY[
    'female_id', 'name', 'age', 'profile_picture_url', 'is_online',
    'last_online_at', 'coin_price', 'rating_avg', 'total_chats',
    'average_response_minutes', 'bio'
  ],
  'females_available_view exposes ONLY the browse-safe column allowlist'
);

SELECT hasnt_column(
  'public', 'females_available_view', 'account_number',
  'View does NOT expose account_number'
);

SELECT hasnt_column(
  'public', 'females_available_view', 'upi_id',
  'View does NOT expose upi_id'
);

-- ---------------------------------------------------------------------------
-- TEST 5-6 — view filters out unverified / suspended / deleted
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT COUNT(*) FROM public.females_available_view
   WHERE female_id IN (
     '11111111-1111-1111-1111-111111111111',
     '22222222-2222-2222-2222-222222222222'
   )),
  1::bigint,
  'View returns only 1 row (the verified female)'
);

SELECT is(
  (SELECT female_id FROM public.females_available_view
   WHERE female_id IN (
     '11111111-1111-1111-1111-111111111111',
     '22222222-2222-2222-2222-222222222222'
   )),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'View returns the verified female, not the pending one'
);

-- ---------------------------------------------------------------------------
-- TEST 7-8 — payout_details RLS: male sees nothing
-- ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}';

SELECT is(
  (SELECT COUNT(*) FROM public.payout_details),
  0::bigint,
  'Male cannot read any payout_details rows via RLS (full-table query)'
);

SELECT is(
  (SELECT COUNT(*) FROM public.payout_details
   WHERE female_id = '11111111-1111-1111-1111-111111111111'),
  0::bigint,
  'Male cannot read payout_details by explicit female_id'
);

-- ---------------------------------------------------------------------------
-- TEST 9 — female reads her own payout_details
-- ---------------------------------------------------------------------------
SET LOCAL "request.jwt.claims" TO '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

SELECT is(
  (SELECT COUNT(*) FROM public.payout_details
   WHERE female_id = '11111111-1111-1111-1111-111111111111'),
  1::bigint,
  'Female can read her own payout_details'
);

-- ---------------------------------------------------------------------------
-- TEST 10 — female cannot read another female's payout_details
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT COUNT(*) FROM public.payout_details
   WHERE female_id = '22222222-2222-2222-2222-222222222222'),
  0::bigint,
  'Female cannot read another female''s payout_details'
);

-- ---------------------------------------------------------------------------
-- TEST 11 — female cannot self-set admin_verified
--   RLS WITH CHECK throws when the new row would violate the policy.
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$UPDATE public.payout_details
    SET is_admin_verified = TRUE
    WHERE female_id = '11111111-1111-1111-1111-111111111111'$$,
  NULL, NULL,
  'Female cannot set is_admin_verified via UPDATE (RLS WITH CHECK fails)'
);

-- ---------------------------------------------------------------------------
-- TEST 12 — Male 1 can favorite verified Female 1
-- ---------------------------------------------------------------------------
SET LOCAL "request.jwt.claims" TO '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}';

SELECT lives_ok(
  $$INSERT INTO public.favorites (male_id, female_id)
    VALUES ('33333333-3333-3333-3333-333333333333',
            '11111111-1111-1111-1111-111111111111')$$,
  'Male can favorite a verified female'
);

-- ---------------------------------------------------------------------------
-- TEST 13 — Male 1 cannot favorite himself
--   Both `favorites_no_self` (CHECK) and `is_browseable_female(self)`
--   (RLS, false because self is a male) reject this. Whichever fires
--   first is fine — we just need the INSERT to throw.
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$INSERT INTO public.favorites (male_id, female_id)
    VALUES ('33333333-3333-3333-3333-333333333333',
            '33333333-3333-3333-3333-333333333333')$$,
  NULL, NULL,
  'Male cannot favorite himself (CHECK constraint or RLS rejects)'
);

-- ---------------------------------------------------------------------------
-- TEST 14 — Male 1 cannot favorite another male (RLS WITH CHECK)
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$INSERT INTO public.favorites (male_id, female_id)
    VALUES ('33333333-3333-3333-3333-333333333333',
            '44444444-4444-4444-4444-444444444444')$$,
  NULL, NULL,
  'Male cannot favorite another male (RLS WITH CHECK fails)'
);

-- ---------------------------------------------------------------------------
-- TEST 15 — Male 1 cannot favorite an unverified female (RLS WITH CHECK)
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$INSERT INTO public.favorites (male_id, female_id)
    VALUES ('33333333-3333-3333-3333-333333333333',
            '22222222-2222-2222-2222-222222222222')$$,
  NULL, NULL,
  'Male cannot favorite an unverified female (RLS WITH CHECK fails)'
);

-- ---------------------------------------------------------------------------
-- TEST 16 — Male cannot impersonate another male in the male_id column
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$INSERT INTO public.favorites (male_id, female_id)
    VALUES ('44444444-4444-4444-4444-444444444444',
            '11111111-1111-1111-1111-111111111111')$$,
  NULL, NULL,
  'Male cannot insert a favorite with someone else''s male_id (auth.uid() = male_id RLS)'
);

-- ---------------------------------------------------------------------------
-- TEST 17 — Male 1 sees his own favorite
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT COUNT(*) FROM public.favorites),
  1::bigint,
  'Male 1 sees his single favorite'
);

-- ---------------------------------------------------------------------------
-- TEST 18 — Male 2 cannot see Male 1's favorites
-- ---------------------------------------------------------------------------
SET LOCAL "request.jwt.claims" TO '{"sub":"44444444-4444-4444-4444-444444444444","role":"authenticated"}';

SELECT is(
  (SELECT COUNT(*) FROM public.favorites),
  0::bigint,
  'Male 2 cannot see Male 1''s favorites'
);

-- ---------------------------------------------------------------------------
-- TEST 19 — A female cannot read the favorites table at all
-- ---------------------------------------------------------------------------
SET LOCAL "request.jwt.claims" TO '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

SELECT is(
  (SELECT COUNT(*) FROM public.favorites),
  0::bigint,
  'Female cannot read the favorites table'
);

-- ---------------------------------------------------------------------------
-- TEST 20 — Male 1 can delete his own favorite (and only his own)
-- ---------------------------------------------------------------------------
SET LOCAL "request.jwt.claims" TO '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}';

DELETE FROM public.favorites
WHERE female_id = '11111111-1111-1111-1111-111111111111';

SELECT is(
  (SELECT COUNT(*) FROM public.favorites),
  0::bigint,
  'Male 1 successfully deleted his own favorite'
);

SELECT * FROM finish();
ROLLBACK;
