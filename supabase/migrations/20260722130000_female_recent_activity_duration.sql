-- =============================================================================
-- Surface room duration in the female "Recent activity" feed.
--
-- female_recent_activity already LEFT JOINs chat_sessions (cs) to prefer the
-- settled amount; expose cs.duration_seconds so the app can show how long each
-- completed chat lasted. NULL for non-chat rows (payouts) and for chat rows
-- ended before duration_seconds was stamped — the app falls back / hides it.
-- (Only the SELECT list gains "durationSeconds"; everything else is unchanged
-- from 20260703120000_chat_session_settlement.sql.)
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
      CASE
        -- Session already settled: show what she actually earned.
        WHEN fe.type = 'chat_earning' THEN
          coalesce(cs.coins_settled, fe.amount_coins) * public.female_inr_per_coin()
        ELSE abs(fe.amount_coins) * public.female_inr_per_coin()
      END AS "amountInr",
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
