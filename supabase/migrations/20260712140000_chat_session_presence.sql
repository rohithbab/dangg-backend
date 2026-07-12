-- =============================================================================
-- Chat presence heartbeat — detect a force-closed / crashed participant.
--
-- A hard force-close (app swiped away) runs no JS, so the graceful
-- background-end never fires and the session lingers `active` until the 5-min
-- message-idle sweep. The surviving participant is left waiting with the timer
-- running. This adds a per-participant "last seen in chat" signal so the
-- surviving side can detect a vanished peer within ~35s and end the session,
-- which its existing status poll then reflects.
--
--   * male_last_seen_at / female_last_seen_at — updated each heartbeat.
--   * chat_session_heartbeat(session)         — caller stamps their own column.
--   * get_chat_session_liveness(session)      — returns status + how long ago
--                                               the PEER was last seen.
-- =============================================================================

ALTER TABLE public.chat_sessions
  ADD COLUMN IF NOT EXISTS male_last_seen_at   timestamptz,
  ADD COLUMN IF NOT EXISTS female_last_seen_at timestamptz;

-- The caller (a participant) marks themselves present. No-op unless the session
-- is active and the caller is the male or female on it.
CREATE OR REPLACE FUNCTION public.chat_session_heartbeat(p_session_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  UPDATE public.chat_sessions
  SET male_last_seen_at   = CASE WHEN male_id   = v_uid THEN now() ELSE male_last_seen_at   END,
      female_last_seen_at = CASE WHEN female_id = v_uid THEN now() ELSE female_last_seen_at END
  WHERE id = p_session_id
    AND status = 'active'
    AND (male_id = v_uid OR female_id = v_uid);
END;
$$;

GRANT EXECUTE ON FUNCTION public.chat_session_heartbeat(uuid) TO authenticated;

-- Returns the session status plus the PEER's liveness (relative to the caller).
-- peerSecondsAgo counts from the peer's last heartbeat, falling back to
-- started_at so a peer who never checked in is measured from session start
-- (tolerating the joining delay before their first heartbeat). NULL if the
-- caller is not a participant.
CREATE OR REPLACE FUNCTION public.get_chat_session_liveness(p_session_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  r public.chat_sessions%ROWTYPE;
  v_peer_last_seen timestamptz;
BEGIN
  SELECT * INTO r FROM public.chat_sessions WHERE id = p_session_id;
  IF NOT FOUND OR (r.male_id <> v_uid AND r.female_id <> v_uid) THEN
    RETURN NULL;
  END IF;

  IF r.male_id = v_uid THEN
    v_peer_last_seen := COALESCE(r.female_last_seen_at, r.started_at);
  ELSE
    v_peer_last_seen := COALESCE(r.male_last_seen_at, r.started_at);
  END IF;

  RETURN jsonb_build_object(
    'status', r.status,
    'peerLastSeenAt', v_peer_last_seen,
    'peerSecondsAgo', GREATEST(0, EXTRACT(EPOCH FROM (now() - v_peer_last_seen))::int)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_chat_session_liveness(uuid) TO authenticated;
