-- =============================================================================
-- Chat ratings — males rate females after a chat (like / dislike).
--
-- Until now the like/dislike screen was UI-only: the verdict was logged and
-- thrown away, so `females.rating_avg` / `females.total_ratings` never moved.
-- This migration adds:
--   1. `chat_ratings`  — one persisted verdict per (male, female), latest wins.
--   2. `submit_chat_rating(...)` — the authoritative write path. It upserts the
--      verdict and recomputes the female's denormalised rating aggregate.
--
-- Rating model: the UI is binary (👍 / 👎), the profile column is a 0–5 avg.
-- We map it as  rating_avg = 5 * likes / total  → all-likes = 5.00,
-- half-and-half = 2.50, all-dislikes = 0.00. `total_ratings` = number of
-- distinct males who rated her.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.chat_ratings (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  male_id   UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  female_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  verdict   TEXT NOT NULL CHECK (verdict IN ('like', 'dislike')),
  comment   TEXT CHECK (comment IS NULL OR char_length(comment) <= 500),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- One standing rating per male→female pair. Re-rating (a later chat) updates
  -- the same row via the RPC's upsert, so a single male can't inflate counts.
  CONSTRAINT chat_ratings_unique_pair UNIQUE (male_id, female_id),

  -- Defence in depth: a user cannot rate themselves.
  CONSTRAINT chat_ratings_no_self CHECK (male_id <> female_id)
);

CREATE INDEX IF NOT EXISTS chat_ratings_female_id_idx ON public.chat_ratings(female_id);
CREATE INDEX IF NOT EXISTS chat_ratings_male_id_idx ON public.chat_ratings(male_id);

COMMENT ON TABLE public.chat_ratings IS
  'Post-chat like/dislike a male leaves for a female. One standing row per pair; '
  'females.rating_avg/total_ratings are recomputed from here by submit_chat_rating.';

-- ---------------------------------------------------------------------------
-- 2. Row Level Security
--    Reads: a male sees his own ratings; a female sees ratings about her.
--    Writes: NONE for clients — all inserts/updates go through the
--    SECURITY DEFINER RPC below, which keeps the aggregate in sync.
-- ---------------------------------------------------------------------------
ALTER TABLE public.chat_ratings ENABLE ROW LEVEL SECURITY;

CREATE POLICY chat_ratings_select_own
  ON public.chat_ratings
  FOR SELECT
  USING (auth.uid() = male_id OR auth.uid() = female_id);

-- ---------------------------------------------------------------------------
-- 3. submit_chat_rating — the authoritative write path
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.submit_chat_rating(
  p_female_id uuid,
  p_verdict   text,
  p_comment   text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_male    uuid := auth.uid();
  v_comment text := nullif(btrim(p_comment), '');
  v_total   int;
  v_likes   int;
  v_avg     numeric(3, 2);
BEGIN
  IF v_male IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING errcode = '28000';
  END IF;

  IF p_verdict NOT IN ('like', 'dislike') THEN
    RAISE EXCEPTION 'verdict must be like or dislike, got %', p_verdict
      USING errcode = '22023';
  END IF;

  IF p_female_id = v_male THEN
    RAISE EXCEPTION 'You cannot rate yourself' USING errcode = '22023';
  END IF;

  -- Target must be a real female profile.
  IF NOT EXISTS (
    SELECT 1 FROM public.females f
    JOIN public.users u ON u.id = f.id
    WHERE f.id = p_female_id AND u.role = 'female'
  ) THEN
    RAISE EXCEPTION 'No such female %', p_female_id USING errcode = '23503';
  END IF;

  -- Upsert this male's standing verdict for her.
  INSERT INTO public.chat_ratings (male_id, female_id, verdict, comment)
  VALUES (v_male, p_female_id, p_verdict, v_comment)
  ON CONFLICT (male_id, female_id)
  DO UPDATE SET
    verdict    = EXCLUDED.verdict,
    comment    = EXCLUDED.comment,
    updated_at = now();

  -- Recompute her aggregate from the source of truth.
  SELECT count(*)::int,
         count(*) FILTER (WHERE verdict = 'like')::int
    INTO v_total, v_likes
  FROM public.chat_ratings
  WHERE female_id = p_female_id;

  v_avg := CASE WHEN v_total > 0
                THEN round((5.0 * v_likes) / v_total, 2)
                ELSE 0 END;

  UPDATE public.females
     SET rating_avg = v_avg,
         total_ratings = v_total
   WHERE id = p_female_id;

  RETURN jsonb_build_object(
    'ratingAvg', v_avg,
    'totalRatings', v_total,
    'verdict', p_verdict
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.submit_chat_rating(uuid, text, text) TO authenticated;
