-- =============================================================================
-- Public, R2-backed bucket for user-owned PUBLIC media (profile images).
--
-- Profile pictures are shown to other users (browse grid, chat, etc.), so they
-- must be publicly readable. Served by storage-api at
--   {SUPABASE_URL}/storage/v1/object/public/users/profile-images/{uid}/{file}
-- which streams from the R2 backend (dangg-media) — no R2 public domain needed.
--
-- Writes are scoped to the owner's own `profile-images/{uid}/…` folder; reads
-- are public (bucket.public = true). Verification selfies stay in the SEPARATE
-- private `verification-photos` bucket — they are NOT affected by this.
-- =============================================================================

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'users',
  'users',
  TRUE,
  10485760,
  ARRAY['image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO UPDATE
  SET public = EXCLUDED.public,
      file_size_limit = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;

-- SELECT is required even for writes: storage-api / supabase-js do
-- `INSERT … RETURNING *`, which needs a SELECT policy or the insert fails with
-- "new row violates row-level security policy". Scope it to the owner's own
-- folder (not the whole bucket): public buckets serve object URLs WITHOUT RLS,
-- so other users still see profile pictures via the public URL, and we avoid a
-- broad policy that would let any authenticated client LIST every file
-- (storage linter 0025_public_bucket_allows_listing).
DROP POLICY IF EXISTS "users_media_select" ON storage.objects;
CREATE POLICY "users_media_select"
  ON storage.objects FOR SELECT TO authenticated
  USING (
    bucket_id = 'users'
    AND (storage.foldername(name))[1] = 'profile-images'
    AND (storage.foldername(name))[2] = auth.uid()::text
  );

-- Owner-only writes under profile-images/{auth.uid()}/…
DROP POLICY IF EXISTS "users_media_insert_own" ON storage.objects;
CREATE POLICY "users_media_insert_own"
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'users'
    AND (storage.foldername(name))[1] = 'profile-images'
    AND (storage.foldername(name))[2] = auth.uid()::text
  );

DROP POLICY IF EXISTS "users_media_update_own" ON storage.objects;
CREATE POLICY "users_media_update_own"
  ON storage.objects FOR UPDATE TO authenticated
  USING (
    bucket_id = 'users'
    AND (storage.foldername(name))[1] = 'profile-images'
    AND (storage.foldername(name))[2] = auth.uid()::text
  )
  WITH CHECK (
    bucket_id = 'users'
    AND (storage.foldername(name))[1] = 'profile-images'
    AND (storage.foldername(name))[2] = auth.uid()::text
  );

DROP POLICY IF EXISTS "users_media_delete_own" ON storage.objects;
CREATE POLICY "users_media_delete_own"
  ON storage.objects FOR DELETE TO authenticated
  USING (
    bucket_id = 'users'
    AND (storage.foldername(name))[1] = 'profile-images'
    AND (storage.foldername(name))[2] = auth.uid()::text
  );
