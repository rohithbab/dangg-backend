-- =============================================================================
-- Migration: Chat-messages Realtime RLS
--
-- PROBLEM
--   Both participants (male and female) subscribe to Realtime `postgres_changes`
--   on `public.chat_messages` for a specific session. But the SELECT policy
--   on `chat_messages` used an inline subquery with `EXISTS` on `public.chat_sessions`.
--   Since RLS is enabled on `chat_sessions`, the Realtime server's WAL processor
--   evaluates this subquery under the subscriber's RLS context, which can fail,
--   time out, or fail to resolve `auth.uid()` properly inside the subquery,
--   causing Realtime to drop the event.
--
-- FIX
--   1. Define a SECURITY DEFINER helper function `chat_message_session_is_active_participant`
--      to check if the user is a participant in an active session. It bypasses
--      RLS on the `chat_sessions` table.
--   2. Re-write the SELECT policy on `chat_messages` using the existing
--      `chat_message_sender_is_participant` SECURITY DEFINER helper.
--   3. Re-write the INSERT policy on `chat_messages` using the new
--      `chat_message_session_is_active_participant` SECURITY DEFINER helper.
-- =============================================================================

-- Helper to check if a user is a participant in an active chat session.
CREATE OR REPLACE FUNCTION public.chat_message_session_is_active_participant(
  p_chat_session_id UUID,
  p_user_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.chat_sessions s
    WHERE s.id = p_chat_session_id
      AND s.status = 'active'
      AND p_user_id IN (s.male_id, s.female_id)
  );
$$;

COMMENT ON FUNCTION public.chat_message_session_is_active_participant(UUID, UUID) IS
  'Checks if user is a participant of an active chat session. Runs as SECURITY DEFINER to bypass RLS for Realtime evaluation.';

-- Drop existing policies on chat_messages
DROP POLICY IF EXISTS chat_messages_select_participant ON public.chat_messages;
DROP POLICY IF EXISTS chat_messages_insert_participant ON public.chat_messages;

-- Create new policies using the SECURITY DEFINER helpers
CREATE POLICY chat_messages_select_participant
  ON public.chat_messages
  FOR SELECT
  USING (
    public.chat_message_sender_is_participant(chat_session_id, auth.uid())
  );

CREATE POLICY chat_messages_insert_participant
  ON public.chat_messages
  FOR INSERT
  WITH CHECK (
    sender_id = auth.uid()
    AND public.chat_message_session_is_active_participant(chat_session_id, auth.uid())
  );

COMMENT ON POLICY chat_messages_select_participant ON public.chat_messages IS
  'Bypasses RLS lookup on sessions via SECURITY DEFINER to ensure Supabase Realtime delivers messages correctly.';
COMMENT ON POLICY chat_messages_insert_participant ON public.chat_messages IS
  'Ensures users can only insert messages if they are part of an active session.';
