-- =============================================================================
-- COIN PACKAGES
--
-- Admin-managed catalogue of purchasable coin packages. Read by every
-- authenticated user (mobile app shows the list). Writes go through admin
-- Edge Functions (service role); no INSERT/UPDATE/DELETE policies for
-- authenticated users.
--
-- All monetary amounts are stored as integer PAISA (1 INR = 100 paisa).
-- Never use float for money.
-- =============================================================================

CREATE TABLE public.coin_packages (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 50),
  coins INTEGER NOT NULL CHECK (coins > 0),
  bonus_coins INTEGER NOT NULL DEFAULT 0 CHECK (bonus_coins >= 0),
  price_paisa INTEGER NOT NULL CHECK (price_paisa > 0),
  tag TEXT CHECK (tag IN ('POPULAR', 'BEST DEAL', 'MAX VALUE') OR tag IS NULL),
  display_order INTEGER NOT NULL DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  -- Generated column: total coins delivered = base + bonus.
  total_coins INTEGER GENERATED ALWAYS AS (coins + bonus_coins) STORED,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX coin_packages_active_order_idx
  ON public.coin_packages(is_active, display_order)
  WHERE is_active = TRUE;

CREATE TRIGGER coin_packages_set_updated_at
  BEFORE UPDATE ON public.coin_packages
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Row Level Security
-- Read: any authenticated user, but only active rows. Admins write via the
-- service role (their Edge Functions can see / mutate everything).
-- ---------------------------------------------------------------------------
ALTER TABLE public.coin_packages ENABLE ROW LEVEL SECURITY;

CREATE POLICY coin_packages_select_active
  ON public.coin_packages
  FOR SELECT
  USING (is_active = TRUE);

-- No INSERT / UPDATE / DELETE policies → authenticated users can't write.

-- ---------------------------------------------------------------------------
-- Seed: 6 starter packages. Prices match the mobile catalogue.
-- ---------------------------------------------------------------------------
INSERT INTO public.coin_packages (name, coins, bonus_coins, price_paisa, tag, display_order)
VALUES
  ('Starter',   100,    0,  10000, NULL,        10),
  ('Basic',     250,   25,  25000, NULL,        20),
  ('Standard',  500,   75,  50000, 'POPULAR',   30),
  ('Pro',      1000,  200, 100000, NULL,        40),
  ('Premium',  2000,  500, 200000, 'BEST DEAL', 50),
  ('Mega',     5000, 1500, 500000, 'MAX VALUE', 60);

COMMENT ON TABLE public.coin_packages IS
  'Purchasable coin packages. Prices in paisa (1 INR = 100 paisa). Admin-managed.';
COMMENT ON COLUMN public.coin_packages.coins IS
  'Base coins delivered on purchase.';
COMMENT ON COLUMN public.coin_packages.bonus_coins IS
  'Promotional bonus coins on top of base. Default 0.';
COMMENT ON COLUMN public.coin_packages.total_coins IS
  'Generated: coins + bonus_coins. Used by the credit_coins call after purchase.';
COMMENT ON COLUMN public.coin_packages.price_paisa IS
  'Price in paisa. e.g., ₹500 = 50000.';
COMMENT ON COLUMN public.coin_packages.tag IS
  'Optional promotional tag shown on the package card (POPULAR, BEST DEAL, MAX VALUE).';
