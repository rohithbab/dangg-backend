-- =============================================================================
-- FAVORITES
--
-- The male's saved list of females. Used by the Male Home favorites
-- carousel and the heart toggle on Female Profile Preview.
--
-- Privacy: a male sees only his own favorites; nothing else can read this
-- table. Insertions are gated server-side by the RLS WITH CHECK clause
-- (favorited row must be a verified female).
--
-- No UPDATE policy by design — favorites are immutable. To "modify" you
-- DELETE then INSERT.
-- =============================================================================

CREATE TABLE public.favorites (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  male_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  female_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- A male cannot favorite the same female twice.
  CONSTRAINT favorites_unique_pair UNIQUE (male_id, female_id),

  -- Defence in depth: a user cannot favorite themselves.
  CONSTRAINT favorites_no_self CHECK (male_id <> female_id)
);

COMMENT ON TABLE public.favorites IS
  'Male users'' saved list of preferred females. Read/write only by the owning male.';
COMMENT ON CONSTRAINT favorites_no_self ON public.favorites IS
  'Prevent users from favoriting themselves.';

CREATE INDEX favorites_male_id_idx ON public.favorites(male_id);
CREATE INDEX favorites_female_id_idx ON public.favorites(female_id);
-- Composite supports "list my favorites newest-first" — the default order
-- on the Home carousel.
CREATE INDEX favorites_male_recent_idx ON public.favorites(male_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
ALTER TABLE public.favorites ENABLE ROW LEVEL SECURITY;

CREATE POLICY favorites_select_own
  ON public.favorites
  FOR SELECT
  USING (auth.uid() = male_id);

-- A male may insert only into his own favorites, and only for verified,
-- active, non-suspended females.
CREATE POLICY favorites_insert_own
  ON public.favorites
  FOR INSERT
  WITH CHECK (
    auth.uid() = male_id
    AND public.current_user_role() = 'male'
    AND male_id <> female_id
    AND EXISTS (
      SELECT 1
      FROM public.users u
      JOIN public.females f ON f.id = u.id
      WHERE u.id = female_id
        AND u.role = 'female'
        AND u.is_active = TRUE
        AND u.is_suspended = FALSE
        AND f.verification_status = 'verified'
    )
  );

CREATE POLICY favorites_delete_own
  ON public.favorites
  FOR DELETE
  USING (auth.uid() = male_id);

-- No UPDATE policy by design — favorites are immutable.

COMMENT ON POLICY favorites_select_own ON public.favorites IS
  'Males see only their own favorites; nothing else can read this table.';
COMMENT ON POLICY favorites_insert_own ON public.favorites IS
  'Insert gated to the calling male, role=male, distinct user, and a verified active female target.';
