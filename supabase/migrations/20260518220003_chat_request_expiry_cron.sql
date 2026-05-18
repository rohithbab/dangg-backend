-- =============================================================================
-- CHAT REQUEST EXPIRY — pg_cron
--
-- Pending chat requests carry an `expires_at` (sent_at + 120s). A minutely
-- pg_cron job sweeps pending rows whose expiry has elapsed and:
--   1. Refunds the male via credit_coins().
--   2. Transitions the row to 'expired'.
--
-- Concurrency strategy:
--   * Each candidate row is locked with `FOR UPDATE SKIP LOCKED` so the
--     cron coexists with user-initiated transitions (accept / decline /
--     cancel). If the female is mid-tap on a request, the cron simply
--     skips that one and grabs the next.
--   * Each iteration runs inside its own BEGIN/EXCEPTION block so a single
--     malformed row (e.g. broken FK) cannot derail the whole sweep — it
--     logs a WARNING and moves on.
--
-- Worst-case latency: 120s (expires_at) + up to 60s (cron interval) = ~3min
-- before a male sees the refund. Acceptable for v1.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- pg_cron extension
--
-- Supabase's local Docker image preloads pg_cron via shared_preload_libraries,
-- so CREATE EXTENSION is sufficient. In Supabase Cloud, the extension must
-- also be enabled once via Database → Extensions; this migration is idempotent.
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ---------------------------------------------------------------------------
-- expire_pending_chat_requests()
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.expire_pending_chat_requests()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_request       RECORD;
  v_refund_txn_id UUID;
  v_expired_count INTEGER := 0;
  v_now           TIMESTAMPTZ := NOW();
BEGIN
  FOR v_request IN
    SELECT id, male_id, chat_cost_coins
      FROM public.chat_requests
     WHERE status = 'pending'
       AND expires_at <= v_now
     -- SKIP LOCKED so the cron coexists with user-initiated transitions.
     FOR UPDATE SKIP LOCKED
  LOOP
    BEGIN
      -- 1. Refund the male via the canonical credit_coins() mutator.
      SELECT transaction_id
        INTO v_refund_txn_id
        FROM public.credit_coins(
          v_request.male_id,
          v_request.chat_cost_coins,
          'chat_refund'::public.coin_transaction_type,
          v_request.id,
          'Chat request expired (no response within timeout)'
        );

      -- 2. Transition the row to 'expired'. The eq.status = 'pending' guard
      --    on the UPDATE protects against a concurrent decline / cancel
      --    landing between our FOR UPDATE acquisition and this write —
      --    SKIP LOCKED already protects us, but the WHERE clause is the
      --    backstop that makes the function safe to call ad-hoc as well.
      UPDATE public.chat_requests
         SET status                 = 'expired',
             responded_at           = v_now,
             response_reason        = 'Expired: no response within timeout window',
             refund_transaction_id  = v_refund_txn_id
       WHERE id = v_request.id
         AND status = 'pending';

      v_expired_count := v_expired_count + 1;
    EXCEPTION WHEN OTHERS THEN
      -- One bad row should not kill the sweep. Log and continue.
      RAISE WARNING 'Failed to expire chat_request %: % (%)',
        v_request.id, SQLERRM, SQLSTATE;
    END;
  END LOOP;

  RETURN v_expired_count;
END;
$$;

COMMENT ON FUNCTION public.expire_pending_chat_requests() IS
  'Sweeps pending chat_requests past their expires_at; refunds coins via credit_coins() and transitions status to expired. SKIP LOCKED so the cron does not contend with user-initiated transitions. Returns count of rows expired in this sweep.';

REVOKE EXECUTE ON FUNCTION public.expire_pending_chat_requests() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.expire_pending_chat_requests() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.expire_pending_chat_requests() FROM anon;
GRANT  EXECUTE ON FUNCTION public.expire_pending_chat_requests() TO service_role;

-- ---------------------------------------------------------------------------
-- Cron schedule — every minute. Idempotent: unschedule any prior version
-- under the same name before scheduling fresh, so re-running this migration
-- on a populated db does not stack duplicate jobs.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_jobid BIGINT;
BEGIN
  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'expire-chat-requests';
  IF v_jobid IS NOT NULL THEN
    PERFORM cron.unschedule(v_jobid);
  END IF;

  PERFORM cron.schedule(
    'expire-chat-requests',
    '* * * * *',
    'SELECT public.expire_pending_chat_requests();'
  );
END$$;
