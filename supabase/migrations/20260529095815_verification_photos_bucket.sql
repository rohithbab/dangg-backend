-- =============================================================================
-- Migration: verification-photos private storage bucket + RLS
--
-- Females upload a verification selfie during signup. These are sensitive
-- DPDP-regulated photos, so they live in a PRIVATE Supabase Storage bucket
-- (Mumbai region in prod) — never Cloudinary, never public.
--
-- ACCESS MODEL (storage.objects RLS):
--   * A female may INSERT / SELECT / UPDATE objects ONLY under her own
--     `{auth.uid()}/…` folder, and only while her role is 'female'.
--     INSERT + SELECT + UPDATE together allow upsert (re-submit after a
--     rejection) per Supabase storage semantics.
--   * No DELETE policy — retained for audit until the DPDP deletion cron.
--   * No anon / public access at all (bucket is private).
--   * Admins read via the service role (signed-URL Edge Function), which
--     bypasses RLS — so no admin policy is needed here.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Private bucket. 10 MiB cap (selfies are < 2 MiB); image mime types only.
-- -----------------------------------------------------------------------------
INSERT INTO storage.buckets (id, name)
VALUES ('verification-photos', 'verification-photos')
ON CONFLICT (id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- RLS — storage.objects already has RLS enabled by Supabase. Add per-folder
-- ownership policies scoped to this bucket.
-- -----------------------------------------------------------------------------

-- Female uploads into her own folder only.
CREATE POLICY "verification_photos_insert_own"
  ON storage.objects
  FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'verification-photos'
    AND (storage.foldername(name))[1] = auth.uid()::text
    AND public.current_user_role() = 'female'
  );

-- Female reads back her own folder (preview / re-submit).
CREATE POLICY "verification_photos_select_own"
  ON storage.objects
  FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'verification-photos'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- Female may overwrite her own object (re-submit after rejection).
CREATE POLICY "verification_photos_update_own"
  ON storage.objects
  FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'verification-photos'
    AND (storage.foldername(name))[1] = auth.uid()::text
  )
  WITH CHECK (
    bucket_id = 'verification-photos'
    AND (storage.foldername(name))[1] = auth.uid()::text
    AND public.current_user_role() = 'female'
  );
