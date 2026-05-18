-- =============================================================================
-- pgTAP — stats + reports + blocks
--
-- Plan covers (20 assertions):
--   Stats — new indexes exist (1-3)
--   Reports — table shape + RLS + CHECK constraints (4-11)
--   Blocks — table + UNIQUE + RLS + view filter both directions (12-18)
--   Cross-domain — suspending a female removes her from the view (19-20)
-- =============================================================================
BEGIN;
SELECT plan(20);

-- ---------------------------------------------------------------------------
-- Setup — 1 male, 2 females (1 verified-online, 1 verified-online).
-- ---------------------------------------------------------------------------
INSERT INTO auth.users (
  instance_id, id, aud, role, email,
  encrypted_password, email_confirmed_at, phone, phone_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
VALUES
  ('00000000-0000-0000-0000-000000000000',
   '90909090-9090-9090-9090-909090909090',
   'authenticated', 'authenticated', NULL, '', NULL, '+919000000090', NOW(),
   '{"provider":"phone","providers":["phone"]}'::jsonb,
   '{"name":"Stats Male","age":30,"role":"male"}'::jsonb,
   NOW(), NOW()),
  ('00000000-0000-0000-0000-000000000000',
   '91919191-9191-9191-9191-919191919191',
   'authenticated', 'authenticated', NULL, '', NULL, '+919000000091', NOW(),
   '{"provider":"phone","providers":["phone"]}'::jsonb,
   '{"name":"Stats Female 1","age":25,"role":"female"}'::jsonb,
   NOW(), NOW()),
  ('00000000-0000-0000-0000-000000000000',
   '92929292-9292-9292-9292-929292929292',
   'authenticated', 'authenticated', NULL, '', NULL, '+919000000092', NOW(),
   '{"provider":"phone","providers":["phone"]}'::jsonb,
   '{"name":"Stats Female 2","age":27,"role":"female"}'::jsonb,
   NOW(), NOW());

UPDATE public.females
   SET verification_status = 'verified', is_online = TRUE, coin_price = 50
 WHERE id IN ('91919191-9191-9191-9191-919191919191',
              '92929292-9292-9292-9292-929292929292');

-- ---------------------------------------------------------------------------
-- STATS — verify the new indexes exist (1-3).
-- ---------------------------------------------------------------------------
SELECT has_index('public', 'chat_requests', 'chat_requests_male_status_idx',
  'stats index chat_requests_male_status_idx exists');
SELECT has_index('public', 'coin_transactions', 'coin_transactions_male_type_idx',
  'stats index coin_transactions_male_type_idx exists');
SELECT has_index('public', 'female_earnings', 'female_earnings_female_type_idx',
  'stats index female_earnings_female_type_idx exists');

-- ---------------------------------------------------------------------------
-- REPORTS — shape (4).
-- ---------------------------------------------------------------------------
SELECT columns_are(
  'public', 'reports',
  ARRAY[
    'id', 'reporter_id', 'reported_id', 'reason', 'description',
    'context_chat_request_id',
    'status', 'admin_id', 'admin_action', 'admin_notes',
    'reviewed_at', 'created_at', 'updated_at'
  ],
  'reports table has the expected column set'
);

-- ---------------------------------------------------------------------------
-- REPORTS — CHECK no-self (5).
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$INSERT INTO public.reports (reporter_id, reported_id, reason)
    VALUES ('90909090-9090-9090-9090-909090909090',
            '90909090-9090-9090-9090-909090909090',
            'harassment')$$,
  '23514', NULL,
  'reports_no_self rejects reporter = reported'
);

-- Insert a valid submitted report for the remaining tests.
INSERT INTO public.reports (id, reporter_id, reported_id, reason)
VALUES (
  'b2b2b2b2-b2b2-b2b2-b2b2-b2b2b2b2b2b2',
  '90909090-9090-9090-9090-909090909090',
  '91919191-9191-9191-9191-919191919191',
  'harassment'
);

-- ---------------------------------------------------------------------------
-- REPORTS — terminal_consistency: action_taken requires admin_action != 'none' (6).
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$UPDATE public.reports
       SET status = 'action_taken',
           admin_id = '90909090-9090-9090-9090-909090909090',
           admin_action = 'none',
           reviewed_at = NOW()
     WHERE id = 'b2b2b2b2-b2b2-b2b2-b2b2-b2b2b2b2b2b2'$$,
  '23514', NULL,
  'terminal_consistency: action_taken with admin_action=none is rejected'
);

-- ---------------------------------------------------------------------------
-- REPORTS — terminal_consistency: dismissed requires admin_action = 'none' (7).
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$UPDATE public.reports
       SET status = 'dismissed',
           admin_id = '90909090-9090-9090-9090-909090909090',
           admin_action = 'warning_issued',
           reviewed_at = NOW()
     WHERE id = 'b2b2b2b2-b2b2-b2b2-b2b2-b2b2b2b2b2b2'$$,
  '23514', NULL,
  'terminal_consistency: dismissed with admin_action!=none is rejected'
);

-- ---------------------------------------------------------------------------
-- REPORTS — RLS reporter sees own (8).
-- ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub":"90909090-9090-9090-9090-909090909090","role":"authenticated"}';

SELECT is(
  (SELECT COUNT(*)::int FROM public.reports
    WHERE reporter_id = '90909090-9090-9090-9090-909090909090'),
  1,
  'Reporter sees own report under RLS'
);

-- ---------------------------------------------------------------------------
-- REPORTS — RLS reported user sees NOTHING (9).
-- ---------------------------------------------------------------------------
SET LOCAL "request.jwt.claims" TO '{"sub":"91919191-9191-9191-9191-919191919191","role":"authenticated"}';

SELECT is(
  (SELECT COUNT(*)::int FROM public.reports),
  0,
  'Reported user has zero read access — anti-retaliation invariant'
);

-- ---------------------------------------------------------------------------
-- REPORTS — RLS admin sees all (10).
-- ---------------------------------------------------------------------------
SET LOCAL "request.jwt.claims" TO
  '{"sub":"99999999-9999-9999-9999-999999999999","role":"authenticated","user_metadata":{"role":"admin"}}';

SELECT is(
  (SELECT COUNT(*)::int FROM public.reports),
  1,
  'Admin (JWT user_metadata.role=admin) reads all reports'
);

-- ---------------------------------------------------------------------------
-- REPORTS — fresh inserts default to submitted with NULL admin fields (11).
-- ---------------------------------------------------------------------------
RESET ROLE;

SELECT is(
  (SELECT status::text || '/' || COALESCE(admin_id::text,'NULL') || '/'
    || COALESCE(reviewed_at::text,'NULL')
     FROM public.reports
    WHERE id = 'b2b2b2b2-b2b2-b2b2-b2b2-b2b2b2b2b2b2'),
  'submitted/NULL/NULL',
  'Freshly inserted report defaults to submitted with NULL admin attribution'
);

-- ---------------------------------------------------------------------------
-- BLOCKS — UNIQUE + no-self constraints (12-13).
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$INSERT INTO public.user_blocks (blocker_id, blocked_id)
    VALUES ('90909090-9090-9090-9090-909090909090',
            '90909090-9090-9090-9090-909090909090')$$,
  '23514', NULL,
  'user_blocks_no_self CHECK rejects self-block'
);

-- Insert one valid block: Male blocks Female 2.
INSERT INTO public.user_blocks (blocker_id, blocked_id)
VALUES ('90909090-9090-9090-9090-909090909090',
        '92929292-9292-9292-9292-929292929292');

SELECT throws_ok(
  $$INSERT INTO public.user_blocks (blocker_id, blocked_id)
    VALUES ('90909090-9090-9090-9090-909090909090',
            '92929292-9292-9292-9292-929292929292')$$,
  '23505', NULL,
  'UNIQUE (blocker_id, blocked_id) rejects duplicate block'
);

-- ---------------------------------------------------------------------------
-- BLOCKS — RLS: blocker sees own; blocked sees nothing (14-15).
-- ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub":"90909090-9090-9090-9090-909090909090","role":"authenticated"}';

SELECT is(
  (SELECT COUNT(*)::int FROM public.user_blocks WHERE blocker_id = '90909090-9090-9090-9090-909090909090'),
  1,
  'Blocker reads own user_blocks row'
);

SET LOCAL "request.jwt.claims" TO '{"sub":"92929292-9292-9292-9292-929292929292","role":"authenticated"}';

SELECT is(
  (SELECT COUNT(*)::int FROM public.user_blocks),
  0,
  'Blocked user has zero read access — disclosure invariant'
);

-- ---------------------------------------------------------------------------
-- BLOCKS — view excludes female the caller blocked (16).
-- Male is the caller, has blocked Female 2. View should return only Female 1.
-- ---------------------------------------------------------------------------
SET LOCAL "request.jwt.claims" TO '{"sub":"90909090-9090-9090-9090-909090909090","role":"authenticated"}';

SELECT is(
  (SELECT array_agg(female_id ORDER BY female_id)
     FROM public.females_available_view
    WHERE female_id IN (
      '91919191-9191-9191-9191-919191919191',
      '92929292-9292-9292-9292-929292929292'
    )),
  ARRAY['91919191-9191-9191-9191-919191919191'::uuid],
  'Browse view excludes a female the caller blocked'
);

-- ---------------------------------------------------------------------------
-- BLOCKS — view excludes female who has blocked the caller (17).
-- Flip: Female 1 blocks Male. Male's view should now also exclude Female 1.
-- ---------------------------------------------------------------------------
RESET ROLE;
INSERT INTO public.user_blocks (blocker_id, blocked_id)
VALUES ('91919191-9191-9191-9191-919191919191',
        '90909090-9090-9090-9090-909090909090');

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub":"90909090-9090-9090-9090-909090909090","role":"authenticated"}';

SELECT is(
  (SELECT COUNT(*)::int
     FROM public.females_available_view
    WHERE female_id IN (
      '91919191-9191-9191-9191-919191919191',
      '92929292-9292-9292-9292-929292929292'
    )),
  0,
  'Browse view excludes a female who blocked the caller (reverse direction)'
);

-- ---------------------------------------------------------------------------
-- BLOCKS — deleting a block restores visibility (18).
-- ---------------------------------------------------------------------------
RESET ROLE;
DELETE FROM public.user_blocks
 WHERE blocker_id = '91919191-9191-9191-9191-919191919191'
   AND blocked_id = '90909090-9090-9090-9090-909090909090';
DELETE FROM public.user_blocks
 WHERE blocker_id = '90909090-9090-9090-9090-909090909090'
   AND blocked_id = '92929292-9292-9292-9292-929292929292';

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub":"90909090-9090-9090-9090-909090909090","role":"authenticated"}';

SELECT is(
  (SELECT COUNT(*)::int
     FROM public.females_available_view
    WHERE female_id IN (
      '91919191-9191-9191-9191-919191919191',
      '92929292-9292-9292-9292-929292929292'
    )),
  2,
  'After deleting blocks in both directions, both females reappear in view'
);

-- ---------------------------------------------------------------------------
-- CROSS-DOMAIN — suspending a female removes her from the view (19-20).
-- ---------------------------------------------------------------------------
RESET ROLE;
UPDATE public.users SET is_suspended = TRUE
 WHERE id = '91919191-9191-9191-9191-919191919191';

SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub":"90909090-9090-9090-9090-909090909090","role":"authenticated"}';

SELECT is(
  (SELECT COUNT(*)::int
     FROM public.females_available_view
    WHERE female_id = '91919191-9191-9191-9191-919191919191'),
  0,
  'Suspended female disappears from females_available_view'
);

SELECT is(
  (SELECT COUNT(*)::int
     FROM public.females_available_view
    WHERE female_id = '92929292-9292-9292-9292-929292929292'),
  1,
  'Non-suspended female still visible'
);

SELECT * FROM finish();
ROLLBACK;
