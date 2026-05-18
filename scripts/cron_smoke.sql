INSERT INTO auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  phone, phone_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
VALUES (
  '00000000-0000-0000-0000-000000000000',
  'fafafafa-fafa-fafa-fafa-fafafafafafa',
  'authenticated', 'authenticated', NULL, '', NULL,
  '+919999000099', NOW(),
  '{"provider":"phone","providers":["phone"]}'::jsonb,
  '{"name":"Cron Test Male","age":33,"role":"male"}'::jsonb,
  NOW(), NOW()
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  phone, phone_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
VALUES (
  '00000000-0000-0000-0000-000000000000',
  'fbfbfbfb-fbfb-fbfb-fbfb-fbfbfbfbfbfb',
  'authenticated', 'authenticated', NULL, '', NULL,
  '+919999000098', NOW(),
  '{"provider":"phone","providers":["phone"]}'::jsonb,
  '{"name":"Cron Test Female","age":24,"role":"female"}'::jsonb,
  NOW(), NOW()
)
ON CONFLICT (id) DO NOTHING;

UPDATE public.males SET coin_balance = 200 WHERE id = 'fafafafa-fafa-fafa-fafa-fafafafafafa';

WITH chg AS (
  SELECT transaction_id FROM public.credit_coins(
    'fafafafa-fafa-fafa-fafa-fafafafafafa'::uuid, -75,
    'chat_charge'::public.coin_transaction_type, NULL, 'Manual cron test: pre-charge'
  )
)
INSERT INTO public.chat_requests
  (male_id, female_id, chat_cost_coins, sent_at, expires_at, charge_transaction_id)
SELECT 'fafafafa-fafa-fafa-fafa-fafafafafafa',
       'fbfbfbfb-fbfb-fbfb-fbfb-fbfbfbfbfbfb',
       75, NOW() - INTERVAL '5 minutes', NOW() - INTERVAL '3 minutes', chg.transaction_id
FROM chg;

\echo === Before sweep ===
SELECT 'balance=' || coin_balance FROM public.males WHERE id='fafafafa-fafa-fafa-fafa-fafafafafafa';
SELECT 'status=' || status || ' refund_txn=' || COALESCE(refund_transaction_id::text,'NULL')
  FROM public.chat_requests WHERE male_id='fafafafa-fafa-fafa-fafa-fafafafafafa';

\echo === Calling expire_pending_chat_requests ===
SELECT 'rows_expired=' || public.expire_pending_chat_requests();

\echo === After sweep ===
SELECT 'balance=' || coin_balance FROM public.males WHERE id='fafafafa-fafa-fafa-fafa-fafafafafafa';
SELECT 'status=' || status || ' refund_txn=' || COALESCE(refund_transaction_id::text,'NULL') || ' reason=' || response_reason
  FROM public.chat_requests WHERE male_id='fafafafa-fafa-fafa-fafa-fafafafafafa';
SELECT 'ledger_entries=' || COUNT(*) FROM public.coin_transactions WHERE male_id='fafafafa-fafa-fafa-fafa-fafafafafafa';

DELETE FROM auth.users WHERE id IN ('fafafafa-fafa-fafa-fafa-fafafafafafa','fbfbfbfb-fbfb-fbfb-fbfb-fbfbfbfbfbfb');
