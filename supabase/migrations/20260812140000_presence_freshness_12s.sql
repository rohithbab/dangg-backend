-- =============================================================================
-- Migration: tighten online-presence freshness 45s -> 12s
--
-- Follow-up to 20260812130000. Realtime presence is now the primary "instant"
-- signal, but its leave can lag ~20s (server disconnect detection). This is the
-- DB fallback / merge floor: with the client heartbeat dropped to 4s, a 12s
-- freshness window still tolerates ~2 missed beats, and the male browse (polls
-- ~4s) drops a force-closed female within ~12-16s even if presence lags.
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
        ) > NOW() - INTERVAL '12 seconds'
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
          ) < NOW() - INTERVAL '12 seconds'
    RETURNING id
  )
  SELECT count(*)::integer INTO v_count FROM stale;

  RETURN v_count;
END;
$$;
