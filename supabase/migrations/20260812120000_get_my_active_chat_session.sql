-- =============================================================================
-- Migration: get_my_active_chat_session() — reconnect after force-close
--
-- When a participant force-closes mid-chat and relaunches, the app lands on
-- home/browse where the partner still shows "busy" (she still has the active
-- session) — but the returning user isn't routed back into their own chat.
-- This RPC lets the client detect, on launch, that the caller is a live
-- participant in an active session and jump straight back into it.
--
-- Returns the active session's chat_request_id (the client's ChatSession route
-- key) + ids/started_at, or NULL when the caller has no active session.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.get_my_active_chat_session()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.chat_sessions;
BEGIN
  IF v_uid IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_row
  FROM public.chat_sessions
  WHERE status = 'active'
    AND (male_id = v_uid OR female_id = v_uid)
  ORDER BY started_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'requestId', v_row.chat_request_id,
    'sessionId', v_row.id,
    'startedAt', v_row.started_at
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_active_chat_session() TO authenticated;

COMMENT ON FUNCTION public.get_my_active_chat_session() IS
  'Returns the caller''s active chat session (requestId/sessionId/startedAt) so '
  'the client can reconnect into it on launch, or NULL if none.';
