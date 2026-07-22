-- =============================================================================
-- Fix: female "Recent activity" earnings were understated for settled chats.
--
-- Under duration billing (20260712160000), chat-sessions-end credits the female
-- `earnCoins = durationSeconds` (1 coin/sec, ₹0.04 each) into female_earnings,
-- while cs.coins_settled records the MALE's charge = ceil(duration/3) coins.
-- female_recent_activity was still using `coalesce(cs.coins_settled, ...)`
-- (a leftover from the pre-duration escrow model), so a settled chat showed the
-- male's coin count — roughly a THIRD of her real earning — even though Today's
-- Earnings (female_home_stats) correctly sums fe.amount_coins.
--
-- Use fe.amount_coins here too so the feed matches Today's Earnings. Keeps the
-- "durationSeconds" field from 20260722130000; only the amount CASE changes.
-- =============================================================================

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
      -- Her actual earning for this row (matches female_home_stats). abs()
      -- flips the sign on payouts (stored negative); chat earnings are positive.
      abs(fe.amount_coins) * public.female_inr_per_coin() AS "amountInr",
      NULL::numeric AS "ratingValue",
      fe.created_at AS "occurredAt",
      cs.duration_seconds AS "durationSeconds"
    FROM public.female_earnings fe
    LEFT JOIN public.chat_requests cr ON cr.id = fe.reference_id AND fe.type = 'chat_earning'
    LEFT JOIN public.chat_sessions cs ON cs.chat_request_id = cr.id
    LEFT JOIN public.users u ON u.id = cr.male_id
    WHERE fe.female_id = auth.uid()
      AND fe.type <> 'chat_earning_reversed'
    ORDER BY fe.created_at DESC
    LIMIT limit_
  ) t;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.female_recent_activity(integer) TO authenticated;
