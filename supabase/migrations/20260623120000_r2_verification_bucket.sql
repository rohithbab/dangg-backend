-- =============================================================================
-- Migration: restructure verification selfie storage to match R2 folder layout
--
-- Replaces the old `verification-photos` bucket (path: {uid}/selfie.jpg) with
-- a new `verification` bucket (path: photos/{uid}/…) so the R2 object key
-- becomes: dangg-media/verification/photos/{uid}/… matching the canonical
-- folder structure:
--
--   verification/
--   └── photos/
--       └── {uid}/
--
-- The old `verification-photos` bucket is left in place for backward
-- compatibility (existing submissions remain accessible by admins).
--
-- ACCESS MODEL:
--   * Female may INSERT / SELECT / UPDATE under photos/{uid}/ only.
--   * No DELETE — retained for audit until the DPDP deletion cron.
--   * Admins read via service role (bypasses RLS).
-- =============================================================================

INSERT INTO storage.buckets (id, name)
VALUES ('verification', 'verification')
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "verification_insert_own"
  ON storage.objects
  FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'verification'
    AND (storage.foldername(name))[1] = 'photos'
    AND (storage.foldername(name))[2] = auth.uid()::text
    AND public.current_user_role() = 'female'
  );

CREATE POLICY "verification_select_own"
  ON storage.objects
  FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'verification'
    AND (storage.foldername(name))[1] = 'photos'
    AND (storage.foldername(name))[2] = auth.uid()::text
  );

CREATE POLICY "verification_update_own"
  ON storage.objects
  FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'verification'
    AND (storage.foldername(name))[1] = 'photos'
    AND (storage.foldername(name))[2] = auth.uid()::text
  )
  WITH CHECK (
    bucket_id = 'verification'
    AND (storage.foldername(name))[1] = 'photos'
    AND (storage.foldername(name))[2] = auth.uid()::text
    AND public.current_user_role() = 'female'
  );
