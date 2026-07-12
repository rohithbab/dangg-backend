-- =============================================================================
-- Background-aware presence (#19/#23): distinguish "stepped away" from "gone".
--
-- When a participant backgrounds the app (JS still runs on the transition) the
-- client marks themselves backgrounded instead of ending the chat. The peer
-- then sees "waiting for them to return" (and pauses the timer) rather than
-- being ejected. If the backgrounded participant never comes back within the
-- grace window — or a hard force-close leaves the heartbeat stale with NO
-- background marker — the peer ends the session (handled client-side using the
-- enriched liveness below).
-- =============================================================================

ALTER TABLE public.chat_sessions
  ADD COLUMN IF NOT EXISTS male_backgrounded_at   timestamptz,
  ADD COLUMN IF NOT EXISTS female_backgrounded_at timestamptz;

-- Caller marks themselves backgrounded (p_backgrounded=true) or foregrounded
-- (false). No-op unless active + participant.
CREATE OR REPLACE FUNCTION public.chat_session_set_background(
  p_session_id uuid,
  p_backgrounded boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_ts  timestamptz := CASE WHEN p_backgrounded THEN now() ELSE NULL END;
BEGIN
  UPDATE public.chat_sessions
  SET male_backgrounded_at   = CASE WHEN male_id   = v_uid THEN v_ts ELSE male_backgrounded_at   END,
      female_backgrounded_at = CASE WHEN female_id = v_uid THEN v_ts ELSE female_backgrounded_at END
  WHERE id = p_session_id
    AND status = 'active'
    AND (male_id = v_uid OR female_id = v_uid);
END;
$$;

GRANT EXECUTE ON FUNCTION public.chat_session_set_background(uuid, boolean) TO authenticated;

-- Liveness for the OTHER participant, now including whether they've explicitly
-- backgrounded (stepped away) vs simply gone quiet (heartbeat stale = crash /
-- force-close). peerSecondsAgo = heartbeat staleness; peerBackgrounded[+Ago] =
-- explicit background marker.
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
  v_peer_bg timestamptz;
BEGIN
  SELECT * INTO r FROM public.chat_sessions WHERE id = p_session_id;
  IF NOT FOUND OR (r.male_id <> v_uid AND r.female_id <> v_uid) THEN
    RETURN NULL;
  END IF;

  IF r.male_id = v_uid THEN
    v_peer_last_seen := COALESCE(r.female_last_seen_at, r.started_at);
    v_peer_bg := r.female_backgrounded_at;
  ELSE
    v_peer_last_seen := COALESCE(r.male_last_seen_at, r.started_at);
    v_peer_bg := r.male_backgrounded_at;
  END IF;

  RETURN jsonb_build_object(
    'status', r.status,
    'peerSecondsAgo', GREATEST(0, EXTRACT(EPOCH FROM (now() - v_peer_last_seen))::int),
    'peerBackgrounded', (v_peer_bg IS NOT NULL),
    'peerBackgroundedSecondsAgo',
      CASE WHEN v_peer_bg IS NULL THEN 0
           ELSE GREATEST(0, EXTRACT(EPOCH FROM (now() - v_peer_bg))::int) END
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_chat_session_liveness(uuid) TO authenticated;
