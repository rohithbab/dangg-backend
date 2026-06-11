-- =============================================================================
-- Migration: Fix browse_females pagination slicing bug
--
-- Rectifies the issue where the last item returned by query was always discarded
-- from the result set, even if total elements returned were fewer than the limit.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.browse_females(
  p_filters jsonb,
  p_offset integer DEFAULT 0,
  p_limit integer DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_quick TEXT;
  v_online_only BOOLEAN;
  v_age_min INT;
  v_age_max INT;
  v_rating TEXT;
  v_price TEXT;
  v_sort_by TEXT;
  
  v_total_online INT;
  v_has_more BOOLEAN;
  v_items jsonb;
BEGIN
  v_quick := p_filters->>'quick';
  v_online_only := coalesce((p_filters->>'onlineOnly')::boolean, false);
  v_age_min := coalesce((p_filters->>'ageMin')::integer, 18);
  v_age_max := coalesce((p_filters->>'ageMax')::integer, 100);
  v_rating := p_filters->>'rating';
  v_price := p_filters->>'price';
  v_sort_by := p_filters->>'sortBy';

  -- Calculate total online matching basic age & block filters
  SELECT count(*)::int INTO v_total_online
  FROM public.females_available_view v
  WHERE v.is_online = true
    AND v.age >= v_age_min
    AND v.age <= v_age_max;

  -- Query items with filters and sorting, fetching p_limit + 1 rows to determine hasMore
  WITH filtered AS (
    SELECT 
      v.female_id AS id,
      v.name,
      v.age,
      v.rating_avg AS rating,
      v.total_chats AS "totalChats",
      v.profile_picture_url AS "imageUrl",
      v.is_online AS "isOnline",
      (f.created_at >= NOW() - INTERVAL '7 days') AS "isNew",
      true AS "isVerified",
      v.coin_price AS "coinPrice",
      v.average_response_minutes AS "averageResponseMinutes",
      v.bio,
      EXISTS (
        SELECT 1 FROM public.favorites fav 
        WHERE fav.male_id = auth.uid() AND fav.female_id = v.female_id
      ) AS "isFavorited"
    FROM public.females_available_view v
    JOIN public.females f ON f.id = v.female_id
    WHERE v.age >= v_age_min
      AND v.age <= v_age_max
      -- Quick filter options
      AND (
        v_quick IS NULL OR v_quick = 'all'
        OR (v_quick = 'online' AND v.is_online = true)
        OR (v_quick = 'new' AND f.created_at >= NOW() - INTERVAL '7 days')
        OR (v_quick = 'topRated' AND v.rating_avg >= 4.5)
        OR (v_quick = 'favorites' AND EXISTS (
          SELECT 1 FROM public.favorites fav 
          WHERE fav.male_id = auth.uid() AND fav.female_id = v.female_id
        ))
      )
      -- Form filters
      AND (NOT v_online_only OR v.is_online = true)
      AND (
        v_rating IS NULL OR v_rating = 'any'
        OR (v_rating = '3plus' AND v.rating_avg >= 3.0)
        OR (v_rating = '4plus' AND v.rating_avg >= 4.0)
        OR (v_rating = '4_5plus' AND v.rating_avg >= 4.5)
      )
      AND (
        v_price IS NULL OR v_price = 'any'
        OR (v_price = 'le50' AND v.coin_price <= 50)
        OR (v_price = '51to100' AND v.coin_price > 50 AND v.coin_price <= 100)
        OR (v_price = '100plus' AND v.coin_price > 100)
      )
    ORDER BY
      CASE WHEN v_sort_by = 'rating' THEN v.rating_avg END DESC,
      CASE WHEN v_sort_by = 'price' THEN v.coin_price END ASC,
      CASE WHEN v_sort_by = 'active' THEN v.total_chats END DESC,
      -- default sort by online first, then last_online_at / created_at
      v.is_online DESC,
      v.last_online_at DESC NULLS LAST,
      f.created_at DESC
    LIMIT p_limit + 1
    OFFSET p_offset
  ),
  formatted AS (
    SELECT jsonb_agg(to_jsonb(filtered)) AS items_arr
    FROM filtered
  )
  SELECT 
    coalesce((SELECT items_arr FROM formatted), '[]'::jsonb),
    coalesce((SELECT jsonb_array_length(items_arr) > p_limit FROM formatted), false)
  INTO v_items, v_has_more;

  -- If there actually is more data, slice off the lookahead element.
  -- Otherwise (fewer elements than limit), keep all elements.
  IF v_has_more THEN
    SELECT jsonb_path_query_array(v_items, '$[0 to last - 1]') INTO v_items;
  END IF;

  RETURN jsonb_build_object(
    'items', v_items,
    'hasMore', v_has_more,
    'totalOnline', v_total_online
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.browse_females(jsonb, integer, integer) TO authenticated;
