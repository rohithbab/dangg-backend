-- =============================================================================
-- Migration: add verification_photo_path to females
--
-- Stores the R2 object key for the submitted verification selfie so that
-- admins can retrieve the photo via a presigned GET.  The column was missing
-- after the storage backend moved from Supabase Storage to R2 (see
-- 20260623120000_r2_verification_bucket.sql).
-- =============================================================================

ALTER TABLE public.females
  ADD COLUMN IF NOT EXISTS verification_photo_path TEXT;

COMMENT ON COLUMN public.females.verification_photo_path IS
  'R2 object key for the verification selfie, e.g. verification/photos/{uid}/{uuid}.jpg. Set when verification_status transitions to pending.';
