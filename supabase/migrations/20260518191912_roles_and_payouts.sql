-- =============================================================================
-- Migration 2: Role-specific tables + signup-trigger extension
--
-- Builds on the initial migration:
--   * `verification_status` enum for the female verification lifecycle
--   * `females` table — verification, availability, stats. Excludes
--     payout (bank/UPI) fields — those live in `payout_details` and are
--     added by the payouts migration.
--   * `males` table — coin balance + lifetime totals
--   * `handle_new_user` trigger extended to also insert into the correct
--     role-specific row, atomically with the public.users insert
--
-- After this migration, OTP signup creates auth.users → public.users →
-- (females | males), all in a single transaction.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Female verification lifecycle
-- -----------------------------------------------------------------------------
CREATE TYPE verification_status AS ENUM ('none', 'pending', 'verified', 'rejected');

COMMENT ON TYPE verification_status IS
  'Female-only verification lifecycle: none (signup) → pending (photo submitted) → verified | rejected.';

-- =============================================================================
-- FEMALES — role-specific data for females
-- =============================================================================
CREATE TABLE public.females (
  id UUID PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,

  -- Verification
  verification_status verification_status NOT NULL DEFAULT 'none',
  verification_submitted_at TIMESTAMPTZ,
  verification_decided_at TIMESTAMPTZ,
  verification_rejection_reason TEXT,

  -- Availability
  is_online BOOLEAN NOT NULL DEFAULT FALSE,
  last_online_at TIMESTAMPTZ,
  -- Heartbeat from the client; cron flips is_online -> false when stale.
  last_heartbeat_at TIMESTAMPTZ,

  -- Public-facing profile
  bio TEXT CHECK (bio IS NULL OR char_length(bio) <= 500),

  -- Aggregate stats — denormalised; kept in sync by triggers / cron in
  -- later migrations. Default zero for a fresh signup.
  rating_avg NUMERIC(3, 2) NOT NULL DEFAULT 0 CHECK (rating_avg BETWEEN 0 AND 5),
  total_chats INTEGER NOT NULL DEFAULT 0 CHECK (total_chats >= 0),
  total_ratings INTEGER NOT NULL DEFAULT 0 CHECK (total_ratings >= 0),
  favorited_count INTEGER NOT NULL DEFAULT 0 CHECK (favorited_count >= 0),

  -- Per-female pricing (admin-default at signup; female can adjust later)
  coin_price INTEGER NOT NULL DEFAULT 50 CHECK (coin_price BETWEEN 10 AND 1000),

  -- Service-quality metric, computed from chat-response times
  average_response_minutes INTEGER NOT NULL DEFAULT 5 CHECK (average_response_minutes >= 0),

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.females IS
  'Female-specific profile + verification + availability + denormalised stats. Payout details live in payout_details.';
COMMENT ON COLUMN public.females.is_online IS
  'TRUE when the female is actively available for chat requests. Heartbeat-driven; cron resets to FALSE after 2 min of silence.';
COMMENT ON COLUMN public.females.rating_avg IS
  'Average like/dislike rating, mapped to 0..5. Recomputed in a trigger when ratings change.';
COMMENT ON COLUMN public.females.coin_price IS
  'Coins the male is charged for a single chat session with this female.';

CREATE INDEX females_verification_idx
  ON public.females(verification_status);
CREATE INDEX females_online_idx
  ON public.females(is_online)
  WHERE is_online = TRUE;
CREATE INDEX females_browse_idx
  ON public.females(verification_status, is_online, rating_avg DESC)
  WHERE verification_status = 'verified';

CREATE TRIGGER females_set_updated_at
  BEFORE UPDATE ON public.females
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- =============================================================================
-- MALES — role-specific data for males
-- =============================================================================
CREATE TABLE public.males (
  id UUID PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,

  -- Wallet
  coin_balance INTEGER NOT NULL DEFAULT 0 CHECK (coin_balance >= 0),

  -- Lifetime aggregates — denormalised for fast Profile/stats reads.
  total_coins_purchased INTEGER NOT NULL DEFAULT 0 CHECK (total_coins_purchased >= 0),
  total_coins_spent INTEGER NOT NULL DEFAULT 0 CHECK (total_coins_spent >= 0),
  chats_initiated INTEGER NOT NULL DEFAULT 0 CHECK (chats_initiated >= 0),

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.males IS
  'Male-specific wallet + lifetime spend / chat totals.';
COMMENT ON COLUMN public.males.coin_balance IS
  'Authoritative coin balance. Mutated only by Edge Functions (purchase, chat-request escrow, refund) — never by the client directly.';

CREATE INDEX males_balance_low_idx ON public.males(coin_balance) WHERE coin_balance < 100;

CREATE TRIGGER males_set_updated_at
  BEFORE UPDATE ON public.males
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- =============================================================================
-- RLS — default deny, explicit self-scoped grants
-- =============================================================================
ALTER TABLE public.females ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.males ENABLE ROW LEVEL SECURITY;

-- Females read their own row.
CREATE POLICY females_select_own
  ON public.females
  FOR SELECT
  USING (auth.uid() = id);

-- Females update their own row, but cannot tamper with verification or
-- aggregate stats — those are managed by admin / triggers / cron.
CREATE POLICY females_update_own
  ON public.females
  FOR UPDATE
  USING (auth.uid() = id)
  WITH CHECK (
    auth.uid() = id
    AND verification_status = (
      SELECT verification_status FROM public.females WHERE id = auth.uid()
    )
    AND rating_avg = (SELECT rating_avg FROM public.females WHERE id = auth.uid())
    AND total_chats = (SELECT total_chats FROM public.females WHERE id = auth.uid())
    AND total_ratings = (SELECT total_ratings FROM public.females WHERE id = auth.uid())
    AND favorited_count = (
      SELECT favorited_count FROM public.females WHERE id = auth.uid()
    )
  );

-- Males read their own row.
CREATE POLICY males_select_own
  ON public.males
  FOR SELECT
  USING (auth.uid() = id);

-- Males CANNOT directly update their row — coin balance, totals etc. are
-- mutated exclusively by Edge Functions running with the service role
-- (chat-request escrow, payment credit, etc.). No update policy = no
-- self-update via the SDK.

COMMENT ON POLICY females_select_own ON public.females IS
  'Females see only their own row.';
COMMENT ON POLICY females_update_own ON public.females IS
  'Females may patch their own row except verification/stat columns managed elsewhere.';
COMMENT ON POLICY males_select_own ON public.males IS
  'Males see only their own row. Updates intentionally not exposed — coin balance is server-mutated only.';

-- =============================================================================
-- EXTENDED AUTH HOOK: also create the role-specific row at signup
--
-- Replaces the earlier definition. Same input contract (name, age, role in
-- raw_user_meta_data) but now atomically inserts:
--   * public.users (shared profile)
--   * public.females OR public.males (role-specific defaults)
--
-- Trigger function is SECURITY DEFINER and runs with the table-owner's
-- privileges, so RLS is bypassed for these inserts (as intended).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_name TEXT;
  v_age INTEGER;
  v_role user_role;
BEGIN
  v_name := NEW.raw_user_meta_data->>'name';
  v_age := NULLIF(NEW.raw_user_meta_data->>'age', '')::INTEGER;
  v_role := (NEW.raw_user_meta_data->>'role')::user_role;

  IF v_name IS NULL OR v_age IS NULL OR v_role IS NULL THEN
    RAISE EXCEPTION 'Signup missing required metadata: name, age, role'
      USING HINT = 'Pass these in `options.data` when calling supabase.auth.signInWithOtp.';
  END IF;

  INSERT INTO public.users (id, phone, role, name, age)
  VALUES (NEW.id, NEW.phone, v_role, v_name, v_age);

  IF v_role = 'female' THEN
    INSERT INTO public.females (id) VALUES (NEW.id);
  ELSE
    INSERT INTO public.males (id) VALUES (NEW.id);
  END IF;

  RETURN NEW;
END;
$$;

-- The trigger `on_auth_user_created` from migration 1 already references
-- this function — CREATE OR REPLACE swapped the body in place. No trigger
-- re-creation needed.
