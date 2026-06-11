-- =============================================================================
-- Migration: Auto-end abandoned chat sessions (force-close / crash backstop)
--
-- PROBLEM
--   A chat_sessions row only ever leaves 'active' when a participant explicitly
--   ends it (chat_sessions_end_participant policy / endChatSession). If either
--   app is force-killed or crashes mid-chat, no end runs and the session stays
--   'active' forever — the other side keeps polling a ghost session.
--
-- DESIGN (mirrors sweep_stale_online_females)
--   `sweep_stale_chat_sessions()` ends every 'active' session with no message
--   activity for longer than the grace window. The graceful client path
--   (end-on-background, see ChatSessionScreen) ends normal closes immediately;
--   this cron is the backstop that catches the cases where no client code got
--   to run. The status='ended' UPDATE broadcasts via Realtime, so the surviving
--   participant's poll/subscription disconnects too.
--
-- GRACE WINDOW
--   5 minutes against COALESCE(last_message_at, started_at). Generous on
--   purpose: without a per-participant liveness ping we can't distinguish
--   "idle but alive" from "dead", and a live paid chat idle for 5 min is
--   already abandoned. (A per-session heartbeat would let us tighten this.)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.sweep_stale_chat_sessions()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count integer;
BEGIN
  WITH stale AS (
    UPDATE public.chat_sessions
    SET status = 'ended',
        ended_at = NOW(),
        ended_by = NULL          -- system-ended; no participant attribution
    WHERE status = 'active'
      AND COALESCE(last_message_at, started_at) < NOW() - INTERVAL '5 minutes'
    RETURNING id
  )
  SELECT count(*)::integer INTO v_count FROM stale;

  RETURN v_count;
END;
$$;

COMMENT ON FUNCTION public.sweep_stale_chat_sessions() IS
  'Ends active chat sessions with no message activity for 5 minutes. Backstop for force-closed/crashed apps; the status=ended UPDATE broadcasts via Realtime so the surviving participant disconnects.';

-- ---------------------------------------------------------------------------
-- Schedule — every minute. Idempotent (unschedule prior, then schedule).
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_jobid BIGINT;
BEGIN
  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'sweep-stale-chat-sessions';
  IF v_jobid IS NOT NULL THEN
    PERFORM cron.unschedule(v_jobid);
  END IF;

  PERFORM cron.schedule(
    'sweep-stale-chat-sessions',
    '* * * * *',
    'SELECT public.sweep_stale_chat_sessions();'
  );
END$$;
