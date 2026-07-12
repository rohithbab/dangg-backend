-- =============================================================================
-- Delete-from-chat-history (per-user soft delete).
--
-- "Delete" hides a chat from the caller's OWN history only. The row (and its
-- messages / earnings) is preserved for the other participant and for audit —
-- each side has its own hidden flag. listChatHistory filters out the caller's
-- hidden rows.
-- =============================================================================

ALTER TABLE public.chat_sessions
  ADD COLUMN IF NOT EXISTS hidden_for_male   boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS hidden_for_female boolean NOT NULL DEFAULT false;

-- Caller hides the chat from their own history. No-op unless they are a
-- participant. Idempotent.
CREATE OR REPLACE FUNCTION public.hide_chat_session(p_session_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  UPDATE public.chat_sessions
  SET hidden_for_male   = CASE WHEN male_id   = v_uid THEN true ELSE hidden_for_male   END,
      hidden_for_female = CASE WHEN female_id = v_uid THEN true ELSE hidden_for_female END
  WHERE id = p_session_id
    AND (male_id = v_uid OR female_id = v_uid);
END;
$$;

GRANT EXECUTE ON FUNCTION public.hide_chat_session(uuid) TO authenticated;
