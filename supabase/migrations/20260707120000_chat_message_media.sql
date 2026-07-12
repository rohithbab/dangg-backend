-- =============================================================================
-- Chat message media attachments (image / video).
--
-- Phase 2 lets a participant send a photo or video from camera/gallery. Bytes
-- go straight to R2 via the media-sign Edge Function (category 'chat'); only the
-- resulting public URL is stored here. Adds:
--   * message_type  text  — 'text' | 'image' | 'video' (default 'text')
--   * media_url     text  — the R2 public URL for image/video messages
--
-- The original body CHECK required 1..2000 chars, which blocks a caption-less
-- media message. Replace it so text messages still require a body, while media
-- messages may have an empty body as long as media_url is present.
-- Idempotent: safe to re-run.
-- =============================================================================

ALTER TABLE public.chat_messages
  ADD COLUMN IF NOT EXISTS message_type text NOT NULL DEFAULT 'text',
  ADD COLUMN IF NOT EXISTS media_url text;

-- Drop the inline body length CHECK (auto-named chat_messages_body_check) and
-- any prior version of the new constraints so this migration re-runs cleanly.
ALTER TABLE public.chat_messages DROP CONSTRAINT IF EXISTS chat_messages_body_check;
ALTER TABLE public.chat_messages DROP CONSTRAINT IF EXISTS chat_messages_type_check;
ALTER TABLE public.chat_messages DROP CONSTRAINT IF EXISTS chat_messages_content_check;

ALTER TABLE public.chat_messages
  ADD CONSTRAINT chat_messages_type_check
    CHECK (message_type IN ('text', 'image', 'video')),
  ADD CONSTRAINT chat_messages_content_check CHECK (
    (message_type = 'text' AND char_length(trim(body)) BETWEEN 1 AND 2000)
    OR (message_type IN ('image', 'video') AND media_url IS NOT NULL
        AND char_length(trim(body)) BETWEEN 0 AND 2000)
  );

COMMENT ON COLUMN public.chat_messages.message_type IS
  'text | image | video. Media rows carry the attachment in media_url; body is an optional caption.';
COMMENT ON COLUMN public.chat_messages.media_url IS
  'R2 public URL of the image/video for non-text messages. NULL for text.';

NOTIFY pgrst, 'reload schema';
