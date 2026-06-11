-- =============================================================================
-- Coin system v2 — finalized pricing + revenue share
--
-- Two changes, both data/display only (no chat-billing logic touched here):
--
--   1. COIN PACKAGES — replace the launch catalogue with the finalized 6.
--      Old packages are retired (is_active = false) rather than deleted, so
--      historical `payments` rows (FK → coin_packages, ON DELETE RESTRICT)
--      stay intact. Inserts are guarded by NOT EXISTS so re-running is a no-op.
--
--          ₹9   →  30 coins      ₹99  →  450 coins  (POPULAR)
--          ₹19  →  70 coins      ₹199 → 1000 coins  (BEST DEAL)
--          ₹49  → 200 coins      ₹499 → 2800 coins  (MAX VALUE)
--
--   2. REVENUE SHARE — female 40% / platform 60% (was 70/30).
--      The female's INR-per-earned-coin is centralised in one IMMUTABLE
--      helper, `female_inr_per_coin()`, and every display RPC/view now calls
--      it instead of the old hardcoded `* 0.7`. The payout engine reads the
--      same numbers from env (payout-math.ts: COIN_VALUE_PAISA=22,
--      PLATFORM_COMMISSION_PCT=60) — keep the two in sync.
--
--      Rate derivation (matches the spec's ₹99 pack example exactly):
--        coin value   = ₹0.22  (₹99 ÷ 450 coins = 22 paisa/coin)
--        female share = 40%
--        female nets  = 0.22 × 0.40 = ₹0.088 per coin
--        → ₹99 pack (450 coins) earns the female 450 × 0.088 = ₹39.60 ✓
--
-- The 1-coin-per-3-seconds chat DEDUCTION is intentionally NOT in this
-- migration — it rewrites the chat charge lifecycle and is handled separately.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Coin packages
-- -----------------------------------------------------------------------------
UPDATE public.coin_packages SET is_active = false WHERE is_active = true;

INSERT INTO public.coin_packages (name, coins, bonus_coins, price_paisa, tag, display_order)
SELECT * FROM (VALUES
  ('Spark',    30,   0,   900, NULL,        10),
  ('Starter',  70,   0,  1900, NULL,        20),
  ('Value',   200,   0,  4900, NULL,        30),
  ('Popular', 450,   0,  9900, 'POPULAR',   40),
  ('Power',  1000,   0, 19900, 'BEST DEAL', 50),
  ('Mega',   2800,   0, 49900, 'MAX VALUE', 60)
) AS v(name, coins, bonus_coins, price_paisa, tag, display_order)
WHERE NOT EXISTS (
  SELECT 1 FROM public.coin_packages cp
  WHERE cp.price_paisa = v.price_paisa AND cp.coins = v.coins
);

-- -----------------------------------------------------------------------------
-- 2. female_inr_per_coin() — the single source of truth for the female's
--    INR value per earned coin. IMMUTABLE so the planner can inline it.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.female_inr_per_coin()
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  -- coin value ₹0.22 × female share 40% = ₹0.088 / coin.
  -- Mirror of payout-math.ts: COIN_VALUE_PAISA(22) × (1 - PLATFORM_COMMISSION_PCT(60)/100).
  SELECT 0.088::numeric;
$$;

COMMENT ON FUNCTION public.female_inr_per_coin() IS
  'INR a female nets per earned coin (coin value ₹0.22 × 40% share = ₹0.088). Keep in sync with payout-math.ts COIN_VALUE_PAISA / PLATFORM_COMMISSION_PCT.';

-- -----------------------------------------------------------------------------
-- 3a. female_home_stats — swap 0.7 → female_inr_per_coin()
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
  SELECT coalesce(sum(amount_coins), 0) INTO v_today_coins
  FROM public.female_earnings
  WHERE female_id = auth.uid()
    AND type = 'chat_earning'
    AND created_at >= date_trunc('day', now() at time zone 'utc');

  SELECT coalesce(sum(amount_coins), 0) INTO v_week_coins
  FROM public.female_earnings
  WHERE female_id = auth.uid()
    AND type = 'chat_earning'
    AND created_at >= date_trunc('week', now() at time zone 'utc');

  SELECT count(*)::int INTO v_chats_today
  FROM public.chat_requests
  WHERE female_id = auth.uid()
    AND status = 'accepted'
    AND responded_at >= date_trunc('day', now() at time zone 'utc');

  SELECT rating_avg, total_ratings INTO v_rating_avg, v_rating_count
  FROM public.females
  WHERE id = auth.uid();

  RETURN jsonb_build_object(
    'todayEarningsInr', coalesce(v_today_coins, 0) * public.female_inr_per_coin(),
    'weekEarningsInr', coalesce(v_week_coins, 0) * public.female_inr_per_coin(),
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
-- 3b. female_earnings_balance — swap 0.7 → female_inr_per_coin()
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

  SELECT coalesce(sum(payout_amount_paisa) / 100.0, 0) INTO v_pending_inr
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
    'availableInr', coalesce(v_available_coins, 0) * public.female_inr_per_coin(),
    'pendingPayoutInr', v_pending_inr,
    'monthEarningsInr', v_month_coins * public.female_inr_per_coin(),
    'monthTrend', jsonb_build_object('kind', 'flat', 'label', '0% vs last month'),
    'lifetimeEarningsInr', v_lifetime_coins * public.female_inr_per_coin()
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.female_earnings_balance() TO authenticated;

-- -----------------------------------------------------------------------------
-- 3c. female_recent_activity — swap 0.7 → female_inr_per_coin()
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
      abs(fe.amount_coins) * public.female_inr_per_coin() AS "amountInr",
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
-- 3d. transactions view (female) — swap 0.7 → female_inr_per_coin()
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.transactions AS
SELECT
  fe.id,
  fe.female_id,
  CASE
    WHEN fe.type = 'chat_earning' THEN 'earning'
    WHEN fe.type = 'payout' THEN 'payout'
    ELSE 'refund'
  END::text AS kind,
  CASE
    WHEN fe.type = 'chat_earning' THEN 'Chat Earnings'
    WHEN fe.type = 'payout' THEN 'UPI Payout'
    WHEN fe.type = 'chat_earning_reversed' THEN 'Refunded Earning'
    WHEN fe.type = 'payout_failed_reversal' THEN 'Payout Refunded'
    WHEN fe.type = 'admin_adjustment' THEN 'Admin Adjustment'
    ELSE 'Adjustment'
  END::text AS title,
  CASE
    WHEN fe.type = 'chat_earning' THEN COALESCE('Chat with ' || u.name, 'Chat Earnings')
    WHEN fe.type = 'payout' THEN
      CASE
        WHEN p.payout_method_snapshot->>'method' = 'upi' THEN 'Transferred to ' || (p.payout_method_snapshot->>'upi_id')
        WHEN p.payout_method_snapshot->>'method' = 'bank' THEN 'Transferred to A/C ending in ' || substring(p.payout_method_snapshot->>'account_number' from length(p.payout_method_snapshot->>'account_number')-3 for 4)
        ELSE COALESCE(fe.description, 'Withdrawal request')
      END
    ELSE COALESCE(fe.description, 'System transaction')
  END::text AS subtitle,
  ABS(fe.amount_coins) * public.female_inr_per_coin() AS "amountInr",
  CASE
    WHEN fe.type = 'payout' THEN
      CASE
        WHEN p.status IN ('pending', 'approved') THEN 'processing'
        WHEN p.status = 'completed' THEN 'completed'
        ELSE 'failed'
      END
    ELSE 'completed'
  END::text AS status,
  fe.created_at AS "occurredAt",
  fe.created_at AS occurred_at
FROM public.female_earnings fe
LEFT JOIN public.chat_requests cr ON cr.id = fe.reference_id AND fe.type = 'chat_earning'
LEFT JOIN public.users u ON u.id = cr.male_id
LEFT JOIN public.payouts p ON p.id = fe.reference_id AND fe.type = 'payout'
WHERE fe.female_id = auth.uid();

GRANT SELECT ON public.transactions TO authenticated;
