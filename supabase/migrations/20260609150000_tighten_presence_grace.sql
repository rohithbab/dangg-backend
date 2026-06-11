-- =============================================================================
-- Migration: Tighten the female presence grace window (3 min → 90s)
--
-- A force-closed / crashed female used to linger on male discovery for up to
-- 3 minutes (the `sweep_stale_online_females` grace) before being flipped
-- offline. Paired with the client heartbeat now firing every 30s (was 60s),
-- a 90s grace still tolerates TWO missed beats — so a brief network blip won't
-- flap a genuinely-online female offline — while dropping a closed app within
-- ~90s. The male grid's 20s reconcile poll then removes the card shortly after.
--
-- Only the INTERVAL changes; the rest of the function is unchanged.
-- =============================================================================

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
          ) < NOW() - INTERVAL '90 seconds'
    RETURNING id
  )
  SELECT count(*)::integer INTO v_count FROM stale;

  RETURN v_count;
END;
$$;

COMMENT ON FUNCTION public.sweep_stale_online_females() IS
  'Flips online -> offline for females with no heartbeat/toggle activity in 90 seconds. The UPDATE broadcasts via Realtime so discovery clients remove the card.';
