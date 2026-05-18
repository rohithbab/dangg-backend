-- =============================================================================
-- expire_pending_chat_requests — extended to drop notifications
--
-- Behaviour matches the prior version exactly (FOR UPDATE SKIP LOCKED scan,
-- per-row exception isolation, atomic refund + status flip) and adds two
-- more INSERTs inside the same per-request transaction:
--
--   * notifications row for the male  → 'chat_request_expired'
--   * notifications row for the female → 'chat_request_missed'
--
-- Migrations are immutable once applied, so this is a CREATE OR REPLACE in
-- a new migration file rather than an edit to 20260518220003_*. The cron
-- schedule does not need updating — the job calls the function by name.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.expire_pending_chat_requests()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_request       RECORD;
  v_refund_txn_id UUID;
  v_male_name     TEXT;
  v_female_name   TEXT;
  v_expired_count INTEGER := 0;
  v_now           TIMESTAMPTZ := NOW();
BEGIN
  FOR v_request IN
    SELECT id, male_id, female_id, chat_cost_coins
      FROM public.chat_requests
     WHERE status = 'pending'
       AND expires_at <= v_now
     FOR UPDATE SKIP LOCKED
  LOOP
    BEGIN
      -- 1. Refund the male.
      SELECT transaction_id
        INTO v_refund_txn_id
        FROM public.credit_coins(
          v_request.male_id,
          v_request.chat_cost_coins,
          'chat_refund'::public.coin_transaction_type,
          v_request.id,
          'Chat request expired (no response within timeout)'
        );

      -- 2. Transition the row.
      UPDATE public.chat_requests
         SET status                = 'expired',
             responded_at          = v_now,
             response_reason       = 'Expired: no response within timeout window',
             refund_transaction_id = v_refund_txn_id
       WHERE id = v_request.id
         AND status = 'pending';

      -- 3. Look up display names for human-readable notification copy.
      --    COALESCE keeps the body sensible even if the row has no name set.
      SELECT COALESCE(name, 'Someone') INTO v_male_name
        FROM public.users WHERE id = v_request.male_id;
      SELECT COALESCE(name, 'Someone') INTO v_female_name
        FROM public.users WHERE id = v_request.female_id;

      -- 4. Notify the male: their request expired and coins were refunded.
      INSERT INTO public.notifications (recipient_id, type, title, body, data)
      VALUES (
        v_request.male_id,
        'chat_request_expired'::public.notification_type,
        'Chat request expired',
        v_female_name || ' did not respond in time. Your coins have been refunded.',
        jsonb_build_object(
          'chat_request_id', v_request.id,
          'to_user_id',      v_request.female_id,
          'to_user_name',    v_female_name,
          'refund_coins',    v_request.chat_cost_coins
        )
      );

      -- 5. Notify the female: she missed an incoming request.
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
      -- One bad row should never kill the sweep.
      RAISE WARNING 'Failed to expire chat_request %: % (%)',
        v_request.id, SQLERRM, SQLSTATE;
    END;
  END LOOP;

  RETURN v_expired_count;
END;
$$;

COMMENT ON FUNCTION public.expire_pending_chat_requests() IS
  'Sweeps pending chat_requests past their expires_at; refunds coins, transitions status to expired, and inserts a notification for both male (chat_request_expired) and female (chat_request_missed). SKIP LOCKED so the cron coexists with user-initiated transitions. Returns count expired.';
