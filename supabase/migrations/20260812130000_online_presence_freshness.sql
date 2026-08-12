-- =============================================================================
-- Migration: near-real-time female online presence
--
-- PROBLEM
--   When an online female force-closes (without toggling off), her heartbeat
--   stops but males kept seeing her online for up to ~90s (grace) + 60s (cron).
--   `females_available_view` exposed the STORED `is_online` column, which only
--   flips false when `sweep_stale_online_females()` runs — so the browse card
--   depended entirely on the slow cron.
--
-- FIX
--   1. Derive `is_online` in the view from heartbeat freshness. Browse polls
--      ~every 5s, so a vanished female now drops off within the grace window
--      without waiting on the cron. GREATEST(last_heartbeat_at, last_online_at)
--      keeps a freshly-toggled female online before her first heartbeat.
--   2. Tighten the sweep grace 90s -> 45s (the client heartbeat drops to 15s in
--      the same change, so 45s still tolerates ~2-3 missed beats). The sweep
--      remains the backstop that resets the stored column + broadcasts offline.
-- =============================================================================

CREATE OR REPLACE VIEW public.females_available_view AS
SELECT
  u.id                              AS female_id,
  u.name,
  u.age,
  u.profile_picture_url,
  (
    f.is_online
    AND GREATEST(
          COALESCE(f.last_heartbeat_at, 'epoch'::timestamptz),
          COALESCE(f.last_online_at,    'epoch'::timestamptz)
        ) > NOW() - INTERVAL '45 seconds'
  )                                 AS is_online,
  f.last_online_at,
  f.coin_price,
  f.rating_avg,
  f.total_chats,
  f.average_response_minutes,
  f.bio
FROM public.users u
INNER JOIN public.females f ON f.id = u.id
WHERE u.is_active = TRUE
  AND u.is_suspended = FALSE
  AND u.deletion_requested_at IS NULL
  AND f.verification_status = 'verified';

GRANT SELECT ON public.females_available_view TO authenticated;

COMMENT ON VIEW public.females_available_view IS
  'Browse-safe view of verified, active, non-suspended females. is_online is '
  'derived from heartbeat freshness (45s) so a force-closed female drops off '
  'browse without waiting on the sweep cron. Explicit column allowlist.';

-- Backstop sweep flips the STORED is_online column; align its grace to 45s.
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
          ) < NOW() - INTERVAL '45 seconds'
    RETURNING id
  )
  SELECT count(*)::integer INTO v_count FROM stale;

  RETURN v_count;
END;
$$;

COMMENT ON FUNCTION public.sweep_stale_online_females() IS
  'Backstop that flips online -> offline for females with no heartbeat/toggle '
  'activity in 45s. The view now derives online freshness for browse; this '
  'resets the stored column and broadcasts offline via Realtime.';
