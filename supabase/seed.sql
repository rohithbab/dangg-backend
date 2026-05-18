-- =============================================================================
-- Seed data — runs after every `supabase db reset`. LOCAL DEV ONLY.
--
-- Direct INSERTs into auth.users won't work (Supabase Auth requires the
-- service-role API to create users so password hashing etc. happens
-- correctly). Real seeding lives in a TypeScript script under `scripts/`
-- which we'll add once auth flows ship.
-- =============================================================================

SELECT 'Seed file ready — populate via the seed script in scripts/ once auth ships.' AS info;
