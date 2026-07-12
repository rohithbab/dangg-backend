-- =============================================================================
-- Duration-only chat billing (no escrow, no refund).
--
-- The male is now charged at chat END by actual duration (ceil(seconds/3)
-- coins, 3s = 1 coin) in chat-sessions-end; the female is credited 1 earning-
-- coin per second there. Nothing is charged/credited on send or accept, and no
-- path refunds (send has no escrow to refund). See the edited edge functions
-- chat-requests-send / -respond / -cancel / chat-sessions-end.
--
-- This migration handles the two DB-side pieces:
--   1. female_inr_per_coin(): each earning-coin now nets ₹0.04 (so a female's
--      earning = seconds × ₹0.04). Payout math env COIN_VALUE_PAISA is set to
--      10 so 10 × (1 - 60%) = ₹0.04 matches.
--   2. expire_pending_chat_requests(): drop the escrow refund (there is none).
-- =============================================================================

-- These constraints encoded the old escrow model:
--   * accepted requests MUST carry an earning_id (we no longer credit on accept)
--   * declined/cancelled/expired MUST carry a refund_transaction_id (no refunds)
-- Duration billing settles everything at chat end, so drop both.
ALTER TABLE public.chat_requests
  DROP CONSTRAINT IF EXISTS chat_requests_accepted_has_earning;
ALTER TABLE public.chat_requests
  DROP CONSTRAINT IF EXISTS chat_requests_refunded_has_refund;

-- 1 earning-coin = 1 second of chat, worth ₹0.04 net to the female.
CREATE OR REPLACE FUNCTION public.female_inr_per_coin()
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $function$
  -- 1 earning-coin = 1s of chat, ₹0.04 net (duration billing).
  -- Mirror of payout-math.ts: COIN_VALUE_PAISA(10) × (1 - PLATFORM_COMMISSION_PCT(60)/100).
  SELECT 0.04::numeric;
$function$;

-- Expire pending requests without any refund (nothing was escrowed).
CREATE OR REPLACE FUNCTION public.expire_pending_chat_requests()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_request       RECORD;
  v_male_name     TEXT;
  v_female_name   TEXT;
  v_expired_count INTEGER := 0;
  v_now           TIMESTAMPTZ := NOW();
BEGIN
  FOR v_request IN
    SELECT id, male_id, female_id
      FROM public.chat_requests
     WHERE status = 'pending'
       AND expires_at <= v_now
     FOR UPDATE SKIP LOCKED
  LOOP
    BEGIN
      -- Transition the row. No refund — duration-only billing never escrowed.
      UPDATE public.chat_requests
         SET status          = 'expired',
             responded_at    = v_now,
             response_reason = 'Expired: no response within timeout window'
       WHERE id = v_request.id
         AND status = 'pending';

      SELECT COALESCE(name, 'Someone') INTO v_male_name
        FROM public.users WHERE id = v_request.male_id;
      SELECT COALESCE(name, 'Someone') INTO v_female_name
        FROM public.users WHERE id = v_request.female_id;

      -- Notify the male: their request expired.
      INSERT INTO public.notifications (recipient_id, type, title, body, data)
      VALUES (
        v_request.male_id,
        'chat_request_expired'::public.notification_type,
        'Chat request expired',
        v_female_name || ' did not respond in time.',
        jsonb_build_object(
          'chat_request_id', v_request.id,
          'to_user_id',      v_request.female_id,
          'to_user_name',    v_female_name
        )
      );

      -- Notify the female: she missed an incoming request.
      INSERT INTO public.notifications (recipient_id, type, title, body, data)
      VALUES (
        v_request.female_id,
        'chat_request_missed'::public.notification_type,
        'Missed chat request',
        'You missed a chat request from ' || v_male_name,
        jsonb_build_object(
          'chat_request_id',  v_request.id,
          'from_user_id',     v_request.male_id,
          'from_user_name',   v_male_name
        )
      );

      v_expired_count := v_expired_count + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'Failed to expire chat_request %: % (%)',
        v_request.id, SQLERRM, SQLSTATE;
    END;
  END LOOP;

  RETURN v_expired_count;
END;
$function$;
