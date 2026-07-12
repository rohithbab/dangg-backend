-- =============================================================================
-- Chat session settlement — bill by actual chat duration, not a flat fee.
--
-- Today chat-requests-respond credits the female the FULL chat_cost_coins
-- escrow the instant she accepts, and ending the session (client-side table
-- update) never touches money — so every completed chat pays the female the
-- exact same amount regardless of how long it actually ran (the Recent
-- Activity feed showing an identical +₹X.XX for every chat is a symptom of
-- this, not a display bug).
--
-- This migration lays the groundwork for settling the DIFFERENCE at session
-- end (see the new chat-sessions-end Edge Function):
--   actual_coins = LEAST(floor(duration_seconds / 3), chat_cost_coins)
--   unused_coins = chat_cost_coins - actual_coins
-- The unused portion is refunded to the male (chat_refund) and reversed from
-- the female (chat_earning_reversed) — reusing the existing ledger types
-- rather than adding new enum values. The original accept-time credit is left
-- as-is because chat_requests has a CHECK constraint requiring earning_id to
-- be set the moment status flips to 'accepted'.
--
-- Also patches female_recent_activity to display the settled (actual) amount
-- once a session has ended, instead of the raw upfront escrow, and to leave
-- the reversal correction out of that 5-item dashboard feed (it still shows
-- up as its own line in the full `transactions` view/ledger).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Settlement columns on chat_sessions.
-- -----------------------------------------------------------------------------
ALTER TABLE public.chat_sessions
  ADD COLUMN IF NOT EXISTS duration_seconds INTEGER,
  ADD COLUMN IF NOT EXISTS coins_settled INTEGER;

COMMENT ON COLUMN public.chat_sessions.duration_seconds IS
  'Wall-clock seconds between started_at and ended_at, stamped atomically by chat-sessions-end. NULL while active.';
COMMENT ON COLUMN public.chat_sessions.coins_settled IS
  'Actual coins the female was credited for this session: LEAST(floor(duration_seconds/3), chat_requests.chat_cost_coins). NULL while active.';

-- -----------------------------------------------------------------------------
-- 2. female_recent_activity — prefer the settled amount over the raw escrow,
--    and never surface the reversal correction row in this feed.
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
      CASE
        -- Session already settled: show what she actually earned.
        WHEN fe.type = 'chat_earning' THEN
          coalesce(cs.coins_settled, fe.amount_coins) * public.female_inr_per_coin()
        ELSE abs(fe.amount_coins) * public.female_inr_per_coin()
      END AS "amountInr",
      NULL::numeric AS "ratingValue",
      fe.created_at AS "occurredAt"
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
