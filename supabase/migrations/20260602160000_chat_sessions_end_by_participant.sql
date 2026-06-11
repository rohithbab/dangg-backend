-- =============================================================================
-- Migration: Let a participant end their own chat session
--
-- `chat_sessions` had only a SELECT policy — there was no way for the male or
-- female to mark a session ended, so "End chat" was a purely local UI action
-- and the other participant was never disconnected.
--
-- This adds an UPDATE policy scoped to the two participants whose net effect is
-- restricted to ENDING the session (WITH CHECK forces the resulting row to
-- status='ended'). Combined with the table's CHECK constraints
-- (`chat_sessions_ended_has_time`), the client must also stamp ended_at, which
-- the app does. The other side detects status='ended' (poll/realtime) and
-- disconnects too.
-- =============================================================================

DROP POLICY IF EXISTS chat_sessions_end_participant ON public.chat_sessions;

CREATE POLICY chat_sessions_end_participant
  ON public.chat_sessions
  FOR UPDATE
  TO authenticated
  USING (auth.uid() IN (male_id, female_id))
  WITH CHECK (
    auth.uid() IN (male_id, female_id)
    AND status = 'ended'
  );

COMMENT ON POLICY chat_sessions_end_participant ON public.chat_sessions IS
  'Either participant may update their own session, but only to end it (status=ended). Lets one user end the chat for both.';
