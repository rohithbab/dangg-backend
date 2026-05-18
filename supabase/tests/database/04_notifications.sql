-- =============================================================================
-- pgTAP tests — notifications domain
--
-- Plan covers:
--   * Table shape + CHECK constraints (read_consistency, title/body length)
--   * RLS SELECT — recipient sees own only
--   * RLS UPDATE — recipient may toggle is_read; tampering with title/etc.
--     is rejected by the WITH CHECK self-subquery
--   * Realtime publication carries notifications
--   * expire_pending_chat_requests writes notifications for both sides
--   * JSONB `data` payload round-trips arbitrary structures
--
-- Whole plan runs in one transaction that rolls back at the end.
-- =============================================================================
BEGIN;
SELECT plan(14);

-- ---------------------------------------------------------------------------
-- Setup — 2 users (1 male, 1 female).
-- ---------------------------------------------------------------------------
INSERT INTO auth.users (
  instance_id, id, aud, role, email,
  encrypted_password, email_confirmed_at, phone, phone_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
VALUES
  ('00000000-0000-0000-0000-000000000000',
   '70707070-7070-7070-7070-707070707070',
   'authenticated', 'authenticated', NULL, '', NULL, '+919000000070', NOW(),
   '{"provider":"phone","providers":["phone"]}'::jsonb,
   '{"name":"Notify Male","age":30,"role":"male"}'::jsonb,
   NOW(), NOW()),
  ('00000000-0000-0000-0000-000000000000',
   '71717171-7171-7171-7171-717171717171',
   'authenticated', 'authenticated', NULL, '', NULL, '+919000000071', NOW(),
   '{"provider":"phone","providers":["phone"]}'::jsonb,
   '{"name":"Notify Female","age":25,"role":"female"}'::jsonb,
   NOW(), NOW());

UPDATE public.males SET coin_balance = 500
 WHERE id = '70707070-7070-7070-7070-707070707070';

-- ---------------------------------------------------------------------------
-- TEST 1 — Table shape: notifications exposes the expected column allowlist.
-- ---------------------------------------------------------------------------
SELECT columns_are(
  'public', 'notifications',
  ARRAY[
    'id', 'recipient_id', 'type', 'title', 'body', 'data',
    'is_read', 'read_at', 'created_at'
  ],
  'notifications has the expected column set'
);

-- Insert a notification for the female via the default test role
-- (RLS-bypassing — mirrors what the service-role notify() helper does).
INSERT INTO public.notifications (recipient_id, type, title, body, data)
VALUES (
  '71717171-7171-7171-7171-717171717171',
  'chat_request_received',
  'Test',
  'Hello from male',
  jsonb_build_object('chat_request_id', 'abc-123', 'from_user_id', '70707070-7070-7070-7070-707070707070')
);

-- ---------------------------------------------------------------------------
-- TEST 2 — RLS SELECT: recipient sees own row.
-- ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"sub":"71717171-7171-7171-7171-717171717171","role":"authenticated"}';

SELECT is(
  (SELECT COUNT(*)::int FROM public.notifications WHERE recipient_id = '71717171-7171-7171-7171-717171717171'),
  1,
  'Female sees her single notification under RLS'
);

-- ---------------------------------------------------------------------------
-- TEST 3 — RLS SELECT: non-recipient sees zero rows.
-- ---------------------------------------------------------------------------
SET LOCAL "request.jwt.claims" TO '{"sub":"70707070-7070-7070-7070-707070707070","role":"authenticated"}';

SELECT is(
  (SELECT COUNT(*)::int FROM public.notifications),
  0,
  'Male cannot read notifications addressed to anyone else'
);

-- ---------------------------------------------------------------------------
-- TEST 4 — RLS UPDATE: recipient may toggle is_read on own row.
-- ---------------------------------------------------------------------------
SET LOCAL "request.jwt.claims" TO '{"sub":"71717171-7171-7171-7171-717171717171","role":"authenticated"}';

SELECT lives_ok(
  $$UPDATE public.notifications
       SET is_read = TRUE, read_at = NOW()
     WHERE recipient_id = '71717171-7171-7171-7171-717171717171'$$,
  'Female can mark her own notification as read'
);

SELECT is(
  (SELECT is_read FROM public.notifications WHERE recipient_id = '71717171-7171-7171-7171-717171717171'),
  TRUE,
  'is_read flipped to TRUE after the recipient update'
);

-- ---------------------------------------------------------------------------
-- TEST 5 — RLS UPDATE WITH CHECK: recipient cannot tamper with title.
--           Postgres throws "new row violates row-level security policy"
--           (SQLSTATE 42501).
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$UPDATE public.notifications
       SET title = 'Hacked'
     WHERE recipient_id = '71717171-7171-7171-7171-717171717171'$$,
  '42501',
  NULL,
  'WITH CHECK rejects UPDATE that mutates title (only read-state is mutable)'
);

-- ---------------------------------------------------------------------------
-- TEST 6 — RLS UPDATE: non-recipient cannot affect another user's row.
--           USING clause filters them out, so 0 rows are touched and no
--           exception is thrown. Assert the row is unchanged afterwards.
-- ---------------------------------------------------------------------------
SET LOCAL "request.jwt.claims" TO '{"sub":"70707070-7070-7070-7070-707070707070","role":"authenticated"}';

UPDATE public.notifications
   SET is_read = FALSE, read_at = NULL
 WHERE recipient_id = '71717171-7171-7171-7171-717171717171';

-- Reset role to peek at the actual row state without RLS.
RESET ROLE;

SELECT is(
  (SELECT is_read FROM public.notifications WHERE recipient_id = '71717171-7171-7171-7171-717171717171'),
  TRUE,
  'Non-recipient UPDATE was filtered out by RLS USING — row unchanged'
);

-- ---------------------------------------------------------------------------
-- TEST 7 — notifications_read_consistency CHECK rejects is_read=TRUE / read_at=NULL.
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$INSERT INTO public.notifications (recipient_id, type, title, body, is_read, read_at)
    VALUES ('71717171-7171-7171-7171-717171717171', 'system', 'X', 'Y', TRUE, NULL)$$,
  '23514',
  NULL,
  'read_consistency CHECK rejects is_read=TRUE with read_at=NULL'
);

-- ---------------------------------------------------------------------------
-- TEST 8 — title length CHECK rejects empty string.
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$INSERT INTO public.notifications (recipient_id, type, title, body)
    VALUES ('71717171-7171-7171-7171-717171717171', 'system', '', 'body')$$,
  '23514',
  NULL,
  'title length CHECK rejects empty title'
);

-- ---------------------------------------------------------------------------
-- TEST 9 — body length CHECK rejects empty string.
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  $$INSERT INTO public.notifications (recipient_id, type, title, body)
    VALUES ('71717171-7171-7171-7171-717171717171', 'system', 'title', '')$$,
  '23514',
  NULL,
  'body length CHECK rejects empty body'
);

-- ---------------------------------------------------------------------------
-- TEST 10 — Realtime publication carries notifications.
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT COUNT(*)::int FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'notifications'),
  1,
  'notifications is published on supabase_realtime'
);

-- ---------------------------------------------------------------------------
-- TEST 11 — expire_pending_chat_requests writes 2 notifications per
--           expired request (chat_request_expired for male, chat_request_missed
--           for female).
-- ---------------------------------------------------------------------------

-- Pre-charge the male and insert a past-expiry pending request.
DO $$
DECLARE
  v_charge_txn UUID;
BEGIN
  SELECT transaction_id INTO v_charge_txn
    FROM public.credit_coins(
      '70707070-7070-7070-7070-707070707070'::uuid, -40,
      'chat_charge'::public.coin_transaction_type, NULL,
      'Test: pre-cron charge'
    );

  INSERT INTO public.chat_requests
    (male_id, female_id, chat_cost_coins, sent_at, expires_at, charge_transaction_id)
  VALUES
    ('70707070-7070-7070-7070-707070707070',
     '71717171-7171-7171-7171-717171717171',
     40,
     NOW() - INTERVAL '10 minutes',
     NOW() - INTERVAL '8 minutes',
     v_charge_txn);
END$$;

-- Snapshot notification counts before.
CREATE TEMP TABLE IF NOT EXISTS _notif_before AS
  SELECT COUNT(*)::int AS n FROM public.notifications;

SELECT is(
  public.expire_pending_chat_requests(),
  1,
  'expire_pending_chat_requests transitioned exactly the past-expiry pending row'
);

-- Two new notifications: one for male (chat_request_expired), one for female (chat_request_missed).
SELECT is(
  (SELECT COUNT(*)::int FROM public.notifications)
    - (SELECT n FROM _notif_before),
  2,
  'expiry sweep inserted exactly 2 notification rows (male + female)'
);

-- ---------------------------------------------------------------------------
-- TEST 12 — JSONB data payload accepts arbitrary structure and round-trips.
-- ---------------------------------------------------------------------------
INSERT INTO public.notifications (recipient_id, type, title, body, data)
VALUES (
  '71717171-7171-7171-7171-717171717171',
  'system',
  'Arbitrary payload',
  'Some structured data attached',
  jsonb_build_object(
    'nested', jsonb_build_object('a', 1, 'b', ARRAY['x','y','z']),
    'flag',   TRUE,
    'count',  42
  )
);

SELECT is(
  (SELECT (data->'nested'->>'a')::int
     FROM public.notifications
    WHERE title = 'Arbitrary payload'),
  1,
  'JSONB data field round-trips arbitrary structured payloads'
);

SELECT * FROM finish();
ROLLBACK;
