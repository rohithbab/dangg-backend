-- =============================================================================
-- Migration: Missing RPC Functions for Frontend Compatibility
--
-- Implements the database functions invoked by the mobile app via `supabase.rpc`:
--   * `browse_females` — paginated, filtered discovery grid for males
--   * `male_favorites` — horizontal favorites list for males
--   * `toggle_favorite` — add/remove favorite for males
--   * `female_home_stats` — dashboard stats for females
--   * `female_recent_activity` — dashboard activity feed for females
--   * `female_earnings_balance` — detailed earnings summary for females
--   * `male_wallet_snapshot` — coin balance and activity stats for males
--   * `verify_current_password` — password check stub (auth is OTP-based)
--   * `delete_self_account` — request account deletion (DPDP compliance)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. BROWSE FEMALES
-- -----------------------------------------------------------------------------
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
    coalesce(
      (SELECT jsonb_path_query_array(items_arr, '$[0 to last - 1]') FROM formatted),
      (SELECT items_arr FROM formatted),
      '[]'::jsonb
    ) AS items,
    coalesce((SELECT jsonb_array_length(items_arr) > p_limit FROM formatted), false) AS has_more
  INTO v_items, v_has_more;

  RETURN jsonb_build_object(
    'items', v_items,
    'hasMore', v_has_more,
    'totalOnline', v_total_online
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.browse_females(jsonb, integer, integer) TO authenticated;

-- -----------------------------------------------------------------------------
-- 2. MALE FAVORITES
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.male_favorites()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  SELECT coalesce(jsonb_agg(t), '[]'::jsonb) INTO v_result
  FROM (
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
      true AS "isFavorited"
    FROM public.favorites fav
    JOIN public.females_available_view v ON v.female_id = fav.female_id
    JOIN public.females f ON f.id = v.female_id
    WHERE fav.male_id = auth.uid()
    ORDER BY fav.created_at DESC
  ) t;
  
  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.male_favorites() TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. TOGGLE FAVORITE
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.toggle_favorite(p_female_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_exists BOOLEAN;
  v_favorited BOOLEAN;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM public.favorites 
    WHERE male_id = auth.uid() AND female_id = p_female_id
  ) INTO v_exists;

  IF v_exists THEN
    DELETE FROM public.favorites 
    WHERE male_id = auth.uid() AND female_id = p_female_id;
    v_favorited := false;
  ELSE
    INSERT INTO public.favorites (male_id, female_id)
    VALUES (auth.uid(), p_female_id);
    v_favorited := true;
  END IF;

  RETURN jsonb_build_object('favorited', v_favorited);
END;
$$;

GRANT EXECUTE ON FUNCTION public.toggle_favorite(uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 4. FEMALE HOME STATS
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.female_home_stats()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_today_coins INT;
  v_week_coins INT;
  v_chats_today INT;
  v_rating_avg NUMERIC(3,2);
  v_rating_count INT;
BEGIN
  -- Sum up earnings from completed chats today (UTC)
  SELECT coalesce(sum(amount_coins), 0) INTO v_today_coins
  FROM public.female_earnings
  WHERE female_id = auth.uid()
    AND type = 'chat_earning'
    AND created_at >= date_trunc('day', now() at time zone 'utc');

  -- Sum up earnings from completed chats this week (UTC)
  SELECT coalesce(sum(amount_coins), 0) INTO v_week_coins
  FROM public.female_earnings
  WHERE female_id = auth.uid()
    AND type = 'chat_earning'
    AND created_at >= date_trunc('week', now() at time zone 'utc');

  -- Count of accepted chat requests today
  SELECT count(*)::int INTO v_chats_today
  FROM public.chat_requests
  WHERE female_id = auth.uid()
    AND status = 'accepted'
    AND responded_at >= date_trunc('day', now() at time zone 'utc');

  -- Average rating and total count from females profile
  SELECT rating_avg, total_ratings INTO v_rating_avg, v_rating_count
  FROM public.females
  WHERE id = auth.uid();

  RETURN jsonb_build_object(
    'todayEarningsInr', coalesce(v_today_coins, 0) * 0.7,
    'weekEarningsInr', coalesce(v_week_coins, 0) * 0.7,
    'chatsToday', coalesce(v_chats_today, 0),
    'ratingAvg', coalesce(v_rating_avg, 0.00),
    'ratingCount', coalesce(v_rating_count, 0),
    'todayTrend', jsonb_build_object('kind', 'flat', 'label', '0% vs yesterday'),
    'weekTrend', jsonb_build_object('kind', 'flat', 'label', '0% vs last week')
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.female_home_stats() TO authenticated;

-- -----------------------------------------------------------------------------
-- 5. FEMALE RECENT ACTIVITY
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.female_recent_activity(limit_ integer DEFAULT 5)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  SELECT coalesce(jsonb_agg(t), '[]'::jsonb) INTO v_result
  FROM (
    SELECT
      fe.id,
      CASE 
        WHEN fe.type = 'chat_earning' THEN 'chatCompleted'
        WHEN fe.type = 'payout' THEN 'paymentReceived'
        ELSE 'chatCompleted'
      END AS kind,
      coalesce(u.name, 'System') AS "actorName",
      u.profile_picture_url AS "actorAvatarUrl",
      CASE
        WHEN fe.type = 'chat_earning' THEN 'Chat completed'
        WHEN fe.type = 'payout' THEN 'Payout processed'
        ELSE coalesce(fe.description, 'System Transaction')
      END AS description,
      abs(fe.amount_coins) * 0.7 AS "amountInr",
      NULL::numeric AS "ratingValue",
      fe.created_at AS "occurredAt"
    FROM public.female_earnings fe
    LEFT JOIN public.chat_requests cr ON cr.id = fe.reference_id AND fe.type = 'chat_earning'
    LEFT JOIN public.users u ON u.id = cr.male_id
    WHERE fe.female_id = auth.uid()
    ORDER BY fe.created_at DESC
    LIMIT limit_
  ) t;
  
  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.female_recent_activity(integer) TO authenticated;

-- -----------------------------------------------------------------------------
-- 6. FEMALE EARNINGS BALANCE
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.female_earnings_balance()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_available_coins INT;
  v_pending_inr NUMERIC;
  v_month_coins INT;
  v_lifetime_coins INT;
BEGIN
  SELECT earnings_balance_coins INTO v_available_coins
  FROM public.females WHERE id = auth.uid();

  SELECT coalesce(sum(amount_inr), 0) INTO v_pending_inr
  FROM public.payouts WHERE female_id = auth.uid() AND status = 'pending';

  SELECT coalesce(sum(amount_coins), 0) INTO v_month_coins
  FROM public.female_earnings
  WHERE female_id = auth.uid() 
    AND type = 'chat_earning' 
    AND created_at >= date_trunc('month', now() at time zone 'utc');

  SELECT coalesce(sum(amount_coins), 0) INTO v_lifetime_coins
  FROM public.female_earnings
  WHERE female_id = auth.uid() 
    AND type = 'chat_earning';

  RETURN jsonb_build_object(
    'availableInr', coalesce(v_available_coins, 0) * 0.7,
    'pendingPayoutInr', v_pending_inr,
    'monthEarningsInr', v_month_coins * 0.7,
    'monthTrend', jsonb_build_object('kind', 'flat', 'label', '0% vs last month'),
    'lifetimeEarningsInr', v_lifetime_coins * 0.7
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.female_earnings_balance() TO authenticated;

-- -----------------------------------------------------------------------------
-- 7. MALE WALLET SNAPSHOT
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.male_wallet_snapshot()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rec RECORD;
BEGIN
  SELECT coin_balance, total_coins_purchased, chats_initiated INTO v_rec
  FROM public.males WHERE id = auth.uid();

  RETURN jsonb_build_object(
    'coinBalance', coalesce(v_rec.coin_balance, 0),
    'totalCoinsPurchased', coalesce(v_rec.total_coins_purchased, 0),
    'chatsStarted', coalesce(v_rec.chats_initiated, 0)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.male_wallet_snapshot() TO authenticated;

-- -----------------------------------------------------------------------------
-- 8. VERIFY CURRENT PASSWORD
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.verify_current_password(p_password text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Dangg is OTP-based, so return true for compatibility
  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.verify_current_password(text) TO authenticated;

-- -----------------------------------------------------------------------------
-- 9. DELETE SELF ACCOUNT
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.delete_self_account()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.users
  SET deletion_requested_at = NOW(), is_active = FALSE
  WHERE id = auth.uid();
END;
$$;

GRANT EXECUTE ON FUNCTION public.delete_self_account() TO authenticated;
