-- =============================================================================
-- Star-based chat ratings.
--
-- Supersedes the binary like/dislike model from 20260628140000_chat_ratings.sql.
-- A male now gives 1–5 stars; `females.rating_avg` becomes the plain MEAN of all
-- stars she's received and `total_ratings` the number of raters. 10 raters →
-- rating_avg = average of their 10 star scores.
-- Idempotent: safe to re-run.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Column: verdict (like/dislike) -> stars (1..5)
-- ---------------------------------------------------------------------------
ALTER TABLE public.chat_ratings ADD COLUMN IF NOT EXISTS stars SMALLINT;

-- Migrate any existing verdict rows (like=5, dislike=1), then drop verdict.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'chat_ratings'
      AND column_name = 'verdict'
  ) THEN
    UPDATE public.chat_ratings
       SET stars = CASE WHEN verdict = 'dislike' THEN 1 ELSE 5 END
     WHERE stars IS NULL;
    ALTER TABLE public.chat_ratings DROP COLUMN verdict;
  END IF;
END $$;

-- Belt-and-suspenders for any straggler, then enforce shape.
UPDATE public.chat_ratings SET stars = 5 WHERE stars IS NULL;

ALTER TABLE public.chat_ratings ALTER COLUMN stars SET NOT NULL;
ALTER TABLE public.chat_ratings DROP CONSTRAINT IF EXISTS chat_ratings_stars_range;
ALTER TABLE public.chat_ratings
  ADD CONSTRAINT chat_ratings_stars_range CHECK (stars BETWEEN 1 AND 5);

-- ---------------------------------------------------------------------------
-- 2. RPC: submit a 1–5 star rating; female aggregate = mean(stars)
--    Signature changes (text verdict -> int stars), so drop the old one first.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.submit_chat_rating(uuid, text, text);

CREATE OR REPLACE FUNCTION public.submit_chat_rating(
  p_female_id uuid,
  p_stars     int,
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
  v_avg     numeric(3, 2);
BEGIN
  IF v_male IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING errcode = '28000';
  END IF;

  IF p_stars IS NULL OR p_stars < 1 OR p_stars > 5 THEN
    RAISE EXCEPTION 'stars must be between 1 and 5, got %', p_stars
      USING errcode = '22023';
  END IF;

  IF p_female_id = v_male THEN
    RAISE EXCEPTION 'You cannot rate yourself' USING errcode = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.females f
    JOIN public.users u ON u.id = f.id
    WHERE f.id = p_female_id AND u.role = 'female'
  ) THEN
    RAISE EXCEPTION 'No such female %', p_female_id USING errcode = '23503';
  END IF;

  -- One standing score per male→female pair (re-rating updates it).
  INSERT INTO public.chat_ratings (male_id, female_id, stars, comment)
  VALUES (v_male, p_female_id, p_stars, v_comment)
  ON CONFLICT (male_id, female_id)
  DO UPDATE SET
    stars      = EXCLUDED.stars,
    comment    = EXCLUDED.comment,
    updated_at = now();

  -- Recompute her aggregate: rating_avg = mean of all star scores.
  SELECT count(*)::int, round(avg(stars), 2)
    INTO v_total, v_avg
  FROM public.chat_ratings
  WHERE female_id = p_female_id;

  UPDATE public.females
     SET rating_avg = coalesce(v_avg, 0),
         total_ratings = v_total
   WHERE id = p_female_id;

  RETURN jsonb_build_object(
    'ratingAvg', coalesce(v_avg, 0),
    'totalRatings', v_total,
    'stars', p_stars
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.submit_chat_rating(uuid, int, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
