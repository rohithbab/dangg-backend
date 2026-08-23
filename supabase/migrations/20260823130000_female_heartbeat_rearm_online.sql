-- =============================================================================
-- Heartbeat re-arms is_online — fixes "female reopens app but stays hidden".
--
-- Bug: a female goes online, then backgrounds/closes the app. After the
-- freshness window her card drops for males (correct), and the 60s sweep
-- (`sweep_stale_online_females`) sets `females.is_online = false`. When she
-- returns, the client resumes heartbeating (her toggle is still "on"), but the
-- old `female_heartbeat()` only stamped `last_heartbeat_at` — `is_online` stayed
-- FALSE. `females_available_view` derives online as `is_online AND fresh`, so
-- `false AND true` kept her hidden from males indefinitely, even though her own
-- toggle showed "online".
--
-- Fix: a heartbeat semantically means "I am online right now", so re-assert
-- `is_online = TRUE` alongside the timestamp. The client only heartbeats while
-- her availability toggle is on — and that toggle is set exclusively by the
-- payout-gated `female-availability-toggle` edge function — so this cannot put
-- a female online who never chose to be. A deliberate toggle-off stops the
-- heartbeat loop and sets `is_online = false`; a stray in-flight beat at that
-- instant self-heals within the freshness window (no further beats → the next
-- sweep turns her back off).
-- =============================================================================

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
  SET last_heartbeat_at = NOW(),
      is_online         = TRUE
  WHERE id = auth.uid();
END;
$$;

GRANT EXECUTE ON FUNCTION public.female_heartbeat() TO authenticated;
