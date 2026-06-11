-- =============================================================================
-- Migration: Female presence heartbeat + stale-online sweep (Phase 7 hardening)
--
-- PROBLEM
--   `females.last_heartbeat_at` exists with a comment "cron flips is_online ->
--   false when stale", but no such cron was ever written. A female whose app
--   crashes, loses network, or is force-killed stays `is_online = true`
--   forever — males see a card they can never actually reach. This breaks the
--   "card disappears when she's gone" guarantee and pollutes discovery.
--
-- DESIGN
--   1. `female_heartbeat()` — cheap RPC the female app calls every ~60s while
--      online. Stamps `last_heartbeat_at = now()`. SECURITY DEFINER + role
--      check; touches only the caller's row.
--   2. `sweep_stale_online_females()` — flips online → offline for anyone whose
--      most recent sign of life (heartbeat OR the toggle-on that set
--      last_online_at) is older than the grace window. The resulting UPDATE
--      broadcasts via Realtime, so male clients drop the card automatically.
--   3. pg_cron job, every minute (matches expire-chat-requests).
--
-- GRACE WINDOW
--   3 minutes, measured against GREATEST(last_heartbeat_at, last_online_at).
--   Because `female-availability-toggle` stamps last_online_at when going
--   online, a freshly-online female has a full 3-minute grace even before her
--   first heartbeat — so this is safe to ship before the client heartbeat loop
--   is wired, it just means an idle online female auto-goes-offline after 3 min.
--
-- PAIR WITH CLIENT
--   Wire `useAvailabilityHeartbeat` (mobile) so an actively-online female keeps
--   refreshing her heartbeat and never gets swept. The cron interval (60s) is
--   well under the grace window (180s): two missed heartbeats tolerated.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Heartbeat RPC
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.female_heartbeat()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.current_user_role() <> 'female' THEN
    RAISE EXCEPTION 'Only females may heartbeat' USING ERRCODE = '42501';
  END IF;

  UPDATE public.females
  SET last_heartbeat_at = NOW()
  WHERE id = auth.uid();
END;
$$;

GRANT EXECUTE ON FUNCTION public.female_heartbeat() TO authenticated;

COMMENT ON FUNCTION public.female_heartbeat() IS
  'Called periodically by an online female client to prove liveness. Stamps last_heartbeat_at; sweep_stale_online_females() takes her offline if it stops.';

-- ---------------------------------------------------------------------------
-- 2. Stale-online sweep
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sweep_stale_online_females()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count integer;
BEGIN
  WITH stale AS (
    UPDATE public.females
    SET is_online = false
    WHERE is_online = true
      AND GREATEST(
            COALESCE(last_heartbeat_at, 'epoch'::timestamptz),
            COALESCE(last_online_at,    'epoch'::timestamptz)
          ) < NOW() - INTERVAL '3 minutes'
    RETURNING id
  )
  SELECT count(*)::integer INTO v_count FROM stale;

  RETURN v_count;
END;
$$;

COMMENT ON FUNCTION public.sweep_stale_online_females() IS
  'Flips online -> offline for females with no heartbeat/toggle activity in 3 minutes. The UPDATE broadcasts via Realtime so discovery clients remove the card.';

-- ---------------------------------------------------------------------------
-- 3. Schedule — every minute. Idempotent (unschedule prior, then schedule).
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_jobid BIGINT;
BEGIN
  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'sweep-stale-online-females';
  IF v_jobid IS NOT NULL THEN
    PERFORM cron.unschedule(v_jobid);
  END IF;

  PERFORM cron.schedule(
    'sweep-stale-online-females',
    '* * * * *',
    'SELECT public.sweep_stale_online_females();'
  );
END$$;
