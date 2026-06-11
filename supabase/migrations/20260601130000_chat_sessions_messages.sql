-- =============================================================================
-- CHAT SESSIONS + MESSAGES
--
-- Bridges Phase-1 accepted chat_requests into real, realtime text chat.
--
-- Model:
--   * One chat_sessions row per accepted chat_requests row.
--   * Both participants can read their own sessions and messages.
--   * Both participants can insert text messages while the session is active.
--   * Realtime is enabled for chat_messages so each side can subscribe by
--     chat_session_id.
-- =============================================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'chat_session_status') THEN
    CREATE TYPE public.chat_session_status AS ENUM ('active', 'ended');
  END IF;
END$$;

COMMENT ON TYPE public.chat_session_status IS
  'Lifecycle for active chat sessions. active accepts messages; ended is terminal.';

CREATE TABLE IF NOT EXISTS public.chat_sessions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

  chat_request_id UUID NOT NULL UNIQUE
    REFERENCES public.chat_requests(id) ON DELETE RESTRICT,
  male_id UUID NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  female_id UUID NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,

  status public.chat_session_status NOT NULL DEFAULT 'active',
  started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ended_at TIMESTAMPTZ,
  ended_by UUID REFERENCES public.users(id) ON DELETE SET NULL,
  last_message_at TIMESTAMPTZ,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chat_sessions_no_self CHECK (male_id <> female_id),
  CONSTRAINT chat_sessions_ended_has_time CHECK (
    status = 'active' OR ended_at IS NOT NULL
  ),
  CONSTRAINT chat_sessions_active_has_no_end CHECK (
    status <> 'active' OR (ended_at IS NULL AND ended_by IS NULL)
  )
);

COMMENT ON TABLE public.chat_sessions IS
  'Live chat room created when a female accepts a chat request.';
COMMENT ON COLUMN public.chat_sessions.chat_request_id IS
  'Accepted chat_requests row that created this session. One-to-one.';

CREATE INDEX IF NOT EXISTS chat_sessions_male_idx
  ON public.chat_sessions(male_id, started_at DESC);
CREATE INDEX IF NOT EXISTS chat_sessions_female_idx
  ON public.chat_sessions(female_id, started_at DESC);
CREATE INDEX IF NOT EXISTS chat_sessions_active_idx
  ON public.chat_sessions(status, last_message_at DESC NULLS LAST)
  WHERE status = 'active';

DROP TRIGGER IF EXISTS chat_sessions_set_updated_at ON public.chat_sessions;
CREATE TRIGGER chat_sessions_set_updated_at
  BEFORE UPDATE ON public.chat_sessions
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE OR REPLACE FUNCTION public.chat_message_sender_is_participant(
  p_chat_session_id UUID,
  p_sender_id UUID
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
      AND p_sender_id IN (s.male_id, s.female_id)
  );
$$;

COMMENT ON FUNCTION public.chat_message_sender_is_participant(UUID, UUID) IS
  'Constraint helper: message sender must be one of the session participants.';

CREATE TABLE IF NOT EXISTS public.chat_messages (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

  chat_session_id UUID NOT NULL
    REFERENCES public.chat_sessions(id) ON DELETE CASCADE,
  sender_id UUID NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  body TEXT NOT NULL CHECK (char_length(trim(body)) BETWEEN 1 AND 2000),

  sent_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chat_messages_sender_is_participant CHECK (
    public.chat_message_sender_is_participant(chat_session_id, sender_id)
  )
);

COMMENT ON TABLE public.chat_messages IS
  'Text messages for active chat sessions. Participants only via RLS.';
COMMENT ON COLUMN public.chat_messages.body IS
  'Plain text message body. Media attachments are intentionally not part of this phase.';

CREATE INDEX IF NOT EXISTS chat_messages_session_sent_idx
  ON public.chat_messages(chat_session_id, sent_at ASC);
CREATE INDEX IF NOT EXISTS chat_messages_sender_idx
  ON public.chat_messages(sender_id, sent_at DESC);

CREATE OR REPLACE FUNCTION public.touch_chat_session_last_message()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.chat_sessions
  SET last_message_at = NEW.sent_at
  WHERE id = NEW.chat_session_id;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.touch_chat_session_last_message() IS
  'AFTER INSERT trigger on chat_messages. Updates chat_sessions.last_message_at.';

DROP TRIGGER IF EXISTS chat_messages_touch_session ON public.chat_messages;
CREATE TRIGGER chat_messages_touch_session
  AFTER INSERT ON public.chat_messages
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_chat_session_last_message();

ALTER TABLE public.chat_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS chat_sessions_select_participant ON public.chat_sessions;
CREATE POLICY chat_sessions_select_participant
  ON public.chat_sessions
  FOR SELECT
  USING (auth.uid() IN (male_id, female_id));

DROP POLICY IF EXISTS chat_messages_select_participant ON public.chat_messages;
CREATE POLICY chat_messages_select_participant
  ON public.chat_messages
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.chat_sessions s
      WHERE s.id = chat_messages.chat_session_id
        AND auth.uid() IN (s.male_id, s.female_id)
    )
  );

DROP POLICY IF EXISTS chat_messages_insert_participant ON public.chat_messages;
CREATE POLICY chat_messages_insert_participant
  ON public.chat_messages
  FOR INSERT
  WITH CHECK (
    sender_id = auth.uid()
    AND EXISTS (
      SELECT 1
      FROM public.chat_sessions s
      WHERE s.id = chat_messages.chat_session_id
        AND s.status = 'active'
        AND auth.uid() IN (s.male_id, s.female_id)
    )
  );

COMMENT ON POLICY chat_sessions_select_participant ON public.chat_sessions IS
  'Only the male and female in the session can read it.';
COMMENT ON POLICY chat_messages_select_participant ON public.chat_messages IS
  'Only session participants can read messages.';
COMMENT ON POLICY chat_messages_insert_participant ON public.chat_messages IS
  'Only session participants can send text messages into active sessions.';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'chat_sessions'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_sessions;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'chat_messages'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_messages;
  END IF;
END$$;
