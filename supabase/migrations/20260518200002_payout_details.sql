-- =============================================================================
-- PAYOUT DETAILS
--
-- One active payout method per female. Sensitive financial PII — RLS is
-- self-only for both reads and writes, and the admin-verification fields
-- are locked from self-mutation (only an admin / cron may set them).
--
-- Data migration: the original `females` table in this codebase never had
-- inline payout columns, so the conditional DO block at the bottom is a
-- no-op here. It is left in place for any environment that does have the
-- old columns — it will safely migrate them and drop the source columns.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Enum: payout_method
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'payout_method') THEN
    CREATE TYPE payout_method AS ENUM ('bank', 'upi');
  END IF;
END $$;

COMMENT ON TYPE payout_method IS
  'Payment method for female earnings. Mutually exclusive — bank or UPI, not both.';

-- ---------------------------------------------------------------------------
-- payout_details
-- ---------------------------------------------------------------------------
CREATE TABLE public.payout_details (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  female_id UUID NOT NULL UNIQUE REFERENCES public.users(id) ON DELETE CASCADE,
  method payout_method NOT NULL,

  -- Bank fields (populated when method = 'bank')
  account_holder_name TEXT,
  account_number TEXT,
  ifsc_code TEXT,

  -- UPI field (populated when method = 'upi')
  upi_id TEXT,

  -- Admin-only verification gate. Female cannot toggle these.
  is_admin_verified BOOLEAN NOT NULL DEFAULT FALSE,
  admin_verified_at TIMESTAMPTZ,
  admin_verified_by UUID,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Method-specific population guard.
  CONSTRAINT payout_details_method_fields CHECK (
    (
      method = 'bank'
      AND account_holder_name IS NOT NULL
      AND account_number IS NOT NULL
      AND ifsc_code IS NOT NULL
      AND upi_id IS NULL
    )
    OR
    (
      method = 'upi'
      AND upi_id IS NOT NULL
      AND account_holder_name IS NULL
      AND account_number IS NULL
      AND ifsc_code IS NULL
    )
  ),

  -- Indian bank account numbers are 9..18 digits.
  CONSTRAINT payout_details_account_number_length CHECK (
    account_number IS NULL OR char_length(account_number) BETWEEN 9 AND 18
  ),

  -- IFSC: 4 letters, then 0, then 6 alphanumeric — e.g. HDFC0001234.
  CONSTRAINT payout_details_ifsc_format CHECK (
    ifsc_code IS NULL OR ifsc_code ~ '^[A-Z]{4}0[A-Z0-9]{6}$'
  ),

  -- UPI: <handle>@<provider>. Liberal but reasonable.
  CONSTRAINT payout_details_upi_format CHECK (
    upi_id IS NULL OR upi_id ~ '^[a-zA-Z0-9._-]+@[a-zA-Z]+$'
  ),

  CONSTRAINT payout_details_holder_name_length CHECK (
    account_holder_name IS NULL
    OR char_length(account_holder_name) BETWEEN 2 AND 100
  )
);

CREATE INDEX payout_details_female_id_idx ON public.payout_details(female_id);
CREATE INDEX payout_details_method_idx ON public.payout_details(method);
CREATE INDEX payout_details_admin_pending_idx
  ON public.payout_details(is_admin_verified)
  WHERE is_admin_verified = FALSE;

CREATE TRIGGER payout_details_set_updated_at
  BEFORE UPDATE ON public.payout_details
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
ALTER TABLE public.payout_details ENABLE ROW LEVEL SECURITY;

CREATE POLICY payout_details_select_own
  ON public.payout_details
  FOR SELECT
  USING (auth.uid() = female_id);

CREATE POLICY payout_details_insert_own
  ON public.payout_details
  FOR INSERT
  WITH CHECK (
    auth.uid() = female_id
    AND public.current_user_role() = 'female'
  );

-- Female may update her own bank / UPI fields, but cannot flip the
-- admin-verified gate or stamp the admin-verified-by / -at audit fields.
-- A separate admin endpoint (server-side, service-role) does that.
CREATE POLICY payout_details_update_own
  ON public.payout_details
  FOR UPDATE
  USING (auth.uid() = female_id)
  WITH CHECK (
    auth.uid() = female_id
    AND is_admin_verified = (
      SELECT is_admin_verified FROM public.payout_details WHERE female_id = auth.uid()
    )
    AND admin_verified_at IS NOT DISTINCT FROM (
      SELECT admin_verified_at FROM public.payout_details WHERE female_id = auth.uid()
    )
    AND admin_verified_by IS NOT DISTINCT FROM (
      SELECT admin_verified_by FROM public.payout_details WHERE female_id = auth.uid()
    )
  );

CREATE POLICY payout_details_delete_own
  ON public.payout_details
  FOR DELETE
  USING (auth.uid() = female_id);

COMMENT ON TABLE public.payout_details IS
  'Payout method for females (bank OR UPI). One-to-one with users.id via female_id. Sensitive PII — strict RLS.';
COMMENT ON COLUMN public.payout_details.is_admin_verified IS
  'Set by admin after manual verification. Locked from self-update via RLS WITH CHECK.';
COMMENT ON COLUMN public.payout_details.admin_verified_by IS
  'Admin user.id who approved. Currently unconstrained; will reference admin users table when admin auth lands.';
COMMENT ON CONSTRAINT payout_details_method_fields ON public.payout_details IS
  'Enforces mutual exclusivity: bank fields when method=bank, upi_id when method=upi.';

-- ---------------------------------------------------------------------------
-- Conditional one-time migration of any inline payout columns from females.
-- No-op in this codebase; safe to leave for environments that have them.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  has_account_number BOOLEAN;
  has_upi_id BOOLEAN;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'females'
      AND column_name = 'account_number'
  ) INTO has_account_number;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'females'
      AND column_name = 'upi_id'
  ) INTO has_upi_id;

  IF has_account_number OR has_upi_id THEN
    INSERT INTO public.payout_details (female_id, method, account_holder_name, account_number, ifsc_code)
    SELECT id, 'bank'::payout_method, account_holder_name, account_number, ifsc_code
    FROM public.females
    WHERE account_number IS NOT NULL
    ON CONFLICT (female_id) DO NOTHING;

    INSERT INTO public.payout_details (female_id, method, upi_id)
    SELECT id, 'upi'::payout_method, upi_id
    FROM public.females
    WHERE upi_id IS NOT NULL
    ON CONFLICT (female_id) DO NOTHING;

    ALTER TABLE public.females DROP COLUMN IF EXISTS account_holder_name;
    ALTER TABLE public.females DROP COLUMN IF EXISTS account_number;
    ALTER TABLE public.females DROP COLUMN IF EXISTS ifsc_code;
    ALTER TABLE public.females DROP COLUMN IF EXISTS upi_id;

    RAISE NOTICE 'Migrated inline payout columns from females into payout_details';
  ELSE
    RAISE NOTICE 'No inline payout columns on females — nothing to migrate';
  END IF;
END $$;
